#!/system/bin/sh
# runner.sh - the benchmark loop, running ON the phone. POSIX sh (toybox).
#
#   sh runner.sh /data/local/tmp/plan.tsv
#
# This is the whole point of the redesign: the loop lives here, so adb is not
# in it. The laptop pushes this script and a plan once, starts it detached,
# and is then free to die for the rest of the run.
#
# THE RULE: this loop never blocks on anything off-device. It writes finished
# arms to the outbox and moves on. Delivery is uploader.sh's problem, and a
# PC that is asleep, firewalled or gone cannot stall a single measurement.
#
# It is also why `measurement_uncertain` no longer exists. The process that
# launches llama-bench is the process that reads its exit code, so "did it
# complete?" is always answerable - which in turn makes re-queuing a failed
# arm safe, where the adb-driven harness could never risk it.
#
# Testability: every path is driven by $DEV, $NC and the stub binaries under
# $DEV, so the entire script runs on a laptop against a fake device tree.
# Nothing here may assume a real phone.

set -u

HERE=$(dirname "$0")
. "$HERE/lib.sh"

PLAN="${1:-$DEV/plan.tsv}"
MODEL="${MODEL:-model.gguf}"
BENCH="${BENCH:-llama-bench}"

# Cooldown policy. Mirrors resultlib.py; preflight refuses to start if they
# disagree, because a silent drift here changes what every number means.
COOL_TARGET_MC="${COOL_TARGET_MC:-42000}"
COOL_MAX_WAIT_S="${COOL_MAX_WAIT_S:-420}"
COOL_MIN_S="${COOL_MIN_S:-45}"
SAMPLE_MS="${SAMPLE_MS:-200}"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-3600}"

# The staged binaries are fully static - no libssl/libcrypto, no
# LD_LIBRARY_PATH - so nothing is prefixed by default. Set LDPATH=<dir> only
# if a dynamically linked build is ever staged again; preflight's --help
# check is what catches the mistake either way.
LDPATH="${LDPATH:-}"
if [ -n "$LDPATH" ]; then LD_PREFIX="env LD_LIBRARY_PATH=$LDPATH "; else LD_PREFIX=""; fi

# Stop conditions. Better to end a run cleanly and say why than to keep
# producing measurements the battery or the disk can no longer support.
MIN_BATTERY="${MIN_BATTERY:-15}"
MIN_FREE_MB="${MIN_FREE_MB:-1500}"
TRACE_FREE_MB="${TRACE_FREE_MB:-3000}"

# How cpu masking is applied.
#
#   taskset   wrap the benchmark in `taskset <mask>` (DEFAULT)
#   cpumask   pass -C <mask> --cpu-strict 1 to llama-bench
#
# taskset is the default because llama-bench's own -C is silently ignored on
# Android: ggml-cpu.c guarded the affinity code with `#elif defined(__gnu_linux__)`,
# which Clang does not define for Android target triples, so the mask fell
# through to an unsupported-platform stub. Fixed upstream in llama.cpp
# PR #26838 (merged 2026-08-10); binaries built before that discard the mask.
#
# Measured here on the Helio G81 Ultra with a 2-thread decode, A75 share of cycles:
#     no mask                  98.8%
#     -C 0x03 --cpu-strict 1   99.5%   <- indistinguishable from no mask
#     taskset 03                0.1%   <- correct
#     taskset c0              100.0%   <- correct
# Switch to MASK_MODE=cpumask once a binary containing the fix is staged;
# preflight verifies whichever mode is configured.
MASK_MODE="${MASK_MODE:-taskset}"

REQUEUE_LIMIT="${REQUEUE_LIMIT:-1}"

# Set AUTO_UPLOADER=0 to run the loop without shipping (used by the tests,
# which drive uploader.sh separately).
AUTO_UPLOADER="${AUTO_UPLOADER:-1}"

# ---------------------------------------------------------------- lifecycle

cleanup() {
  log "runner exiting; reaping and releasing lock"
  reap_orphans
  release_lock
}

state() {
  # A one-line status the uploader turns into a heartbeat. This is the only
  # visibility available when adb is gone for hours.
  printf 'arm=%s done=%s total=%s temp_mC=%s battery=%s outbox_mb=%s\n' \
    "$1" "$2" "$3" "$(temp_mC)" "$(bat_capacity)" "$(dir_mb "$OUTBOX")" \
    > "$STATE"
}

# ----------------------------------------------------------------- cooldown

cooldown() {
  # Temperature-gated, not a fixed sleep. Prints "<waited> <temp> <timedout>".
  #
  # A fixed sleep would let a hot device start an arm and produce a throttled
  # number indistinguishable from a real one. Timing out is recorded, never
  # silently ignored - the arm is skipped rather than run hot.
  _t0=$(boottime); _timedout=0
  sleep "$COOL_MIN_S"
  while :; do
    _t=$(temp_mC)
    _now=$(boottime)
    _el=$(awk "BEGIN{printf \"%d\", $_now - $_t0}")
    [ -z "$_t" ] && break
    [ "$_t" -le "$COOL_TARGET_MC" ] && break
    if [ "$_el" -gt "$COOL_MAX_WAIT_S" ]; then _timedout=1; break; fi
    sleep 10
  done
  _t=$(temp_mC)
  _now=$(boottime)
  echo "$(awk "BEGIN{printf \"%.1f\", $_now - $_t0}") ${_t:-0} $_timedout"
}

# ---------------------------------------------------------------- telemetry

telemetry_start() {
  # One persistent sysfs sampler. NOTE the redirections and the absence of a
  # `cd X &&` prefix: backgrounding a compound list keeps a copy of the
  # caller's stdout, which used to hang the invoking shell forever.
  _csv="$1"
  nohup sh "$DEV/sampler.sh" "$SAMPLE_MS" "$_csv" "$DEV/zones.txt" \
    </dev/null >/dev/null 2>&1 &
  SAMPLER_PID=$!
  track_pid "$SAMPLER_PID"
}

telemetry_stop() {
  [ -n "${SAMPLER_PID:-}" ] || return 0
  kill -TERM "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
  return 0
}

trace_start() {
  # Perfetto runs entirely on-device; adb only ever delivered this command.
  # Both paths are SELinux-mandated: the config must live in CFG_DIR and the
  # output under TRACE_DIR, or the capture silently produces nothing.
  _tag="$1"; _out="$2"
  mkdir -p "$CFG_DIR" "$TRACE_DIR" 2>/dev/null
  _cfg="$CFG_DIR/tc_$_tag.pbtx"
  sed "s/duration_ms:.*/duration_ms: $((15 * 60 * 1000))/" \
    "$HERE/trace_config.pbtx" > "$_cfg" 2>/dev/null
  # last line of --background-wait is the daemon pid
  _pf=$(perfetto -c "$_cfg" --txt -o "$_out" --background-wait 2>/dev/null \
        | tail -1 | tr -dc '0-9')
  track_pid "$_pf"
  echo "$_pf"
}

trace_stop() {
  # Wait for the daemon to actually exit before copying: perfetto flushes on
  # SIGTERM, and copying early yields a truncated trace that looks valid.
  _pid="$1"
  [ -z "$_pid" ] && return 0
  kill -TERM "$_pid" 2>/dev/null
  _n=0
  while [ -d "/proc/$_pid" ] && [ "$_n" -lt 30 ]; do
    sleep 1; _n=$((_n + 1))
  done
  [ -d "/proc/$_pid" ] && log "  warn: perfetto $_pid still alive after 30s"
  return 0
}

# ----------------------------------------------------------------- workload

bench_cmd() {
  # Build the llama-bench command for one arm. Kept as one place so the
  # counters and control paths cannot drift from the sweep path.
  # NOTE the `env`: `timeout N VAR=value cmd` does not work - timeout treats
  # "VAR=value" as the program name and exits 127. That failure looks exactly
  # like a missing binary, so it is worth keeping explicit.
  _threads="$1"; _mask="$2"; _np="$3"; _ng="$4"; _reps="$5"; _json="$6"
  _c="$LD_PREFIX$(mask_prefix "$_mask")./$BENCH -m $MODEL -p $_np -n $_ng"
  _c="$_c -t $_threads -r $_reps -o json"
  [ "$_mask" != "free" ] && [ "$MASK_MODE" = "cpumask" ] \
    && _c="$_c -C $_mask --cpu-strict 1"
  echo "$_c > $_json 2>$_json.err"
}

mask_prefix() {
  # Command prefix that applies the cpu mask, or nothing.
  # taskset wants a bare hex mask, so the 0x is stripped.
  [ "$1" = "free" ] && return 0
  [ "$MASK_MODE" = "taskset" ] || return 0
  printf 'taskset %s ' "$(echo "$1" | sed 's/^0[xX]//')"
}

# --------------------------------------------------------------------- arm

run_arm() {
  # Fields arrive positionally from the plan row; see plan.py COLUMNS.
  arm_id="$1"; pass="$2"; config="$3"; threads="$4"; mask="$5"; test="$6"
  reps="$7"; rep_batch="$8"; n_prompt="$9"; n_gen="${10}"
  want_tel="${11}"; want_trace="${12}"; events="${13}"; variant="${14}"

  reap_orphans

  sd=$(stage_dir "$arm_id")
  rm -rf "$sd"; mkdir -p "$sd"

  bat0=$(bat_status); cap0=$(bat_capacity)

  set -- $(cooldown)
  cool_wait="$1"; entry_temp="$2"; cool_timeout="$3"

  attempt_id=$(new_id)
  devjson="$DEV/bench_$arm_id.json"
  devrep="$DEV/perf_$arm_id.txt"
  devcsv="$DEV/telemetry_$arm_id.csv"
  devtrace="$TRACE_DIR/$arm_id.pb"
  rm -f "$devjson" "$devjson.err" "$devrep" "$devcsv" "$devtrace"

  rc=0; timed_out=0; pf_pid=""; trace_captured=0

  if [ "$cool_timeout" = "1" ]; then
    # Never run a hot bench and present it as normal.
    log "  !! $arm_id SKIPPED - thermal gate timed out (entry ${entry_temp}mC)"
    t0=$(boottime); t1="$t0"
  else
    [ "$want_tel" = "1" ] && telemetry_start "$devcsv"
    if [ "$want_trace" = "1" ]; then
      if [ "$(free_mb)" -lt "$TRACE_FREE_MB" ]; then
        log "  $arm_id: skipping trace, only $(free_mb)MB free"
      else
        pf_pid=$(trace_start "$arm_id" "$devtrace")
        sleep 1                      # let ftrace warm up
      fi
    fi

    t0=$(boottime)
    if [ "$events" = "-" ]; then
      cmd=$(bench_cmd "$threads" "$mask" "$n_prompt" "$n_gen" "$reps" "$devjson")
      ( cd "$DEV" && eval "timeout $BENCH_TIMEOUT $cmd" ) ; rc=$?
    else
      maskarg=""
      [ "$mask" != "free" ] && [ "$MASK_MODE" = "cpumask" ] \
        && maskarg="-C $mask --cpu-strict 1"
      tsprefix=$(mask_prefix "$mask")
      ( cd "$DEV" && eval "timeout $BENCH_TIMEOUT ${LD_PREFIX}simpleperf stat -e $events --per-core -o $devrep -- \
          ${tsprefix}./$BENCH -m $MODEL -p $n_prompt -n $n_gen -t $threads \
          -r $reps $maskarg -o json > $devjson" ) ; rc=$?
    fi
    t1=$(boottime)
    [ "$rc" = "124" ] && timed_out=1

    trace_stop "$pf_pid"
    [ "$want_tel" = "1" ] && telemetry_stop
    [ -s "$devtrace" ] && trace_captured=1
  fi

  bat1=$(bat_status)

  # ---- collect artifacts into staging -------------------------------------
  [ -s "$devjson" ] && cp "$devjson" "$sd/bench.json"
  [ -s "$devrep" ]  && cp "$devrep"  "$sd/perf.txt"
  samples=0
  if [ -f "$devcsv" ]; then
    cp "$devcsv" "$sd/telemetry.csv"
    samples=$(wc -l < "$devcsv" 2>/dev/null | tr -d ' ')
  fi

  # Suspend detection: sampler.sh writes every SAMPLE_MS, so a hole far
  # beyond that cadence means the device froze under us. This is the only
  # suspend signal available without root, and an arm spanning one has
  # corrupt wall-clock timing and energy. Threshold matches resultlib's
  # SUSPEND_GAP_S. See that constant for the calibration data - 8-thread
  # configs starve this sampler badly and a tight threshold discards them.
  suspended=0
  if [ -f "$sd/telemetry.csv" ]; then
    suspended=$(awk -F, 'BEGIN{hit=0}
                         NR>1 && $1+0>0 {
                           if (prev>0 && $1-prev > 60.0) hit=1
                           prev=$1
                         }
                         END { print hit }' "$sd/telemetry.csv")
  fi

  # ---- the sidecar the PC turns into a Result -----------------------------
  {
    echo "arm_id=$arm_id"
    echo "pass=$pass"
    echo "config=$config"
    echo "threads=$threads"
    echo "mask=$mask"
    echo "test=$test"
    echo "rep_batch=$rep_batch"
    echo "reps=$reps"
    echo "n_prompt=$n_prompt"
    echo "n_gen=$n_gen"
    echo "bench=$BENCH"
    echo "variant=$variant"
    echo "events=$events"
    echo "attempt_id=$attempt_id"
    echo "boot_id=$(boot_id)"
    echo "t_start_boottime=$t0"
    echo "t_end_boottime=$t1"
    echo "rc=$rc"
    echo "timed_out=$timed_out"
    echo "cool_wait_s=$cool_wait"
    echo "entry_temp_mC=$entry_temp"
    echo "cool_timeout=$cool_timeout"
    echo "battery_status_start=$bat0"
    echo "battery_capacity_start=$cap0"
    echo "battery_status_end=$bat1"
    echo "suspend_detected=$suspended"
    echo "sampler_samples=$samples"
    echo "telemetry=$want_tel"
    echo "trace_captured=$trace_captured"
    echo "trace_evicted=0"
    echo "wakelock=$(wakelock_state)"
  } > "$sd/meta.kv"

  # ---- decide whether it earns a re-queue --------------------------------
  # Judged BEFORE commit, while the staged files still exist. The verdict
  # goes to a file rather than stdout: run_arm also logs, and parsing a
  # verdict back out of mixed log output is exactly the kind of fragility
  # that hides in a 16 h unattended run.
  #
  # Re-queuing is only safe because this process observed the exit code
  # itself. The adb harness could never do this - it could not distinguish
  # "failed" from "finished but I lost the connection", so a retry risked
  # silently recording a second measurement as if it were the first.
  if [ "$cool_timeout" = "1" ]; then
    verdict=requeue
  elif [ "$rc" != "0" ] || [ "$suspended" = "1" ]; then
    log "  !! $arm_id FAILED rc=$rc suspended=$suspended"
    verdict=requeue
  elif [ ! -s "$sd/bench.json" ]; then
    log "  !! $arm_id produced no benchmark JSON"
    verdict=requeue
  else
    log "  $arm_id ok (rc=0, ${samples} telemetry samples)"
    verdict=ok
  fi
  echo "$verdict" > "$DEV/.last_verdict"

  # ---- commit -------------------------------------------------------------
  # The trace goes to the BULK queue, separately, so a 16 MB diagnostic can
  # never delay or displace the 30 KB measurement it belongs to.
  if [ "$trace_captured" = "1" ]; then
    mkdir -p "$STAGING/$arm_id.trace"
    cp "$devtrace" "$STAGING/$arm_id.trace/trace.perfetto-trace" 2>/dev/null
    cp "$sd/meta.kv" "$STAGING/$arm_id.trace/meta.kv" 2>/dev/null
    commit_arm "$arm_id.trace" "$OUTBOX_BULK"
  fi
  commit_arm "$arm_id" "$OUTBOX"

  rm -f "$devjson" "$devjson.err" "$devrep" "$devcsv" "$devtrace"
}

# ---------------------------------------------------------------- uploader

ensure_uploader() {
  # Checked at every arm boundary, not just at startup: over 16 hours the
  # uploader can be killed by the low-memory killer, and a dead uploader is
  # silent - the run keeps succeeding while nothing reaches the PC.
  [ "$AUTO_UPLOADER" = "1" ] || return 0
  if [ -f "$DEV/.uploader.pid" ]; then
    _up=$(cat "$DEV/.uploader.pid" 2>/dev/null)
    [ -n "$_up" ] && [ -d "/proc/$_up" ] && return 0
    log "uploader died; restarting it"
  fi
  nohup sh "$HERE/uploader.sh" </dev/null >/dev/null 2>&1 &
  echo $! > "$DEV/.uploader.pid"
}

# --------------------------------------------------------------------- main

main() {
  mkdir -p "$OUTBOX" "$OUTBOX_BULK" "$STAGING"
  rm -f "$DEV/runner.done"

  acquire_lock || die "another runner holds $LOCKDIR - refusing to start"
  trap cleanup EXIT INT TERM

  [ -f "$PLAN" ] || die "no plan at $PLAN"

  # The apparatus is validated before the matrix, not after it. Set FORCE=1
  # to run anyway - useful when only the masked configs are affected and you
  # deliberately want the unmasked ones.
  if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
    if sh "$HERE/preflight.sh" >> "$RUNLOG" 2>&1; then
      log "preflight OK"
    elif [ "${FORCE:-0}" = "1" ]; then
      log "!! preflight FAILED but FORCE=1 - continuing anyway"
    else
      log "!! preflight FAILED - refusing to start. See $RUNLOG, or FORCE=1"
      exit 2
    fi
    # ship the report first so a remote failure is visible without adb
    if [ -f "$DEV/preflight.kv" ]; then
      mkdir -p "$STAGING/preflight"
      cp "$DEV/preflight.kv" "$STAGING/preflight/meta.kv"
      commit_arm "preflight" "$OUTBOX"
    fi
  fi
  total=$(grep -cv '^#' "$PLAN")
  log "=== runner starting: $total arms from $PLAN ==="
  log "bench=$BENCH model=$MODEL wakelock=$(wakelock_state) free=$(free_mb)MB"

  # zones.txt is read by sampler.sh; empty is fine (it falls back to none)
  ls -d /sys/class/thermal/thermal_zone* 2>/dev/null > "$DEV/zones.txt" \
    || : > "$DEV/zones.txt"

  requeue=""
  done_n=0
  pass_n=0

  while [ "$pass_n" -le "$REQUEUE_LIMIT" ]; do
    ROWS="$DEV/.rows"
    if [ "$pass_n" -eq 0 ]; then
      grep -v '^#' "$PLAN" > "$ROWS"
    else
      [ -s "$DEV/.requeue" ] || break
      log "=== re-queue pass $pass_n: $(grep -c . "$DEV/.requeue") arms ==="
      mv "$DEV/.requeue" "$ROWS"
    fi

    # Redirected, NOT piped. `... | while read` runs the loop in a subshell,
    # so every variable it sets - the progress counter, the stop flags -
    # would be discarded the moment the loop ended.
    while IFS='	' read -r arm_id pass config threads mask \
        test reps rep_batch n_prompt n_gen tel trace events variant; do
      [ -z "${arm_id:-}" ] && continue

      # Resume: the ledger survives a reboot, so restarting the runner picks
      # up exactly where it stopped without re-running finished work.
      if ledger_has "$arm_id"; then
        continue
      fi

      # Stop conditions, checked per arm rather than once at startup - a
      # 16 h run can exhaust either of these halfway through.
      cap=$(bat_capacity)
      if [ "$cap" -ge 0 ] && [ "$cap" -lt "$MIN_BATTERY" ]; then
        log "STOPPING: battery ${cap}% below ${MIN_BATTERY}%"
        echo "battery" > "$DEV/runner.stopped"
        break
      fi
      if [ "$(free_mb)" -lt "$MIN_FREE_MB" ]; then
        log "STOPPING: only $(free_mb)MB free, below ${MIN_FREE_MB}MB"
        echo "storage" > "$DEV/runner.stopped"
        break
      fi

      ensure_uploader
      done_n=$((done_n + 1))
      state "$arm_id" "$done_n" "$total"
      log "[$done_n/$total] $arm_id (t=$threads mask=$mask reps=$reps)"

      run_arm "$arm_id" "$pass" "$config" "$threads" "$mask" \
              "$test" "$reps" "$rep_batch" "$n_prompt" "$n_gen" \
              "$tel" "$trace" "$events" "$variant"
      verdict=$(cat "$DEV/.last_verdict" 2>/dev/null)

      ledger_add "$arm_id"
      if [ "$verdict" = "requeue" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$arm_id" "$pass" "$config" "$threads" "$mask" "$test" "$reps" \
          "$rep_batch" "$n_prompt" "$n_gen" "$tel" "$trace" "$events" \
          "$variant" >> "$DEV/.requeue"
        # a re-queued arm must be runnable again on the next pass
        if [ -f "$LEDGER" ]; then
          grep -vxF "$arm_id" "$LEDGER" > "$LEDGER.new" 2>/dev/null
          mv "$LEDGER.new" "$LEDGER" 2>/dev/null
        fi
      fi
    done < "$ROWS"

    rm -f "$ROWS"
    [ -f "$DEV/runner.stopped" ] && break
    pass_n=$((pass_n + 1))
  done

  state "done" "$done_n" "$total"
  # Tells the uploader it may exit once the queues are empty. Written last,
  # after every arm has been committed.
  echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$DEV/runner.done"
  log "=== runner finished: $done_n arms attempted ==="
}

main "$@"
