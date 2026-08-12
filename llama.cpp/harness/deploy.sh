#!/usr/bin/env bash
# deploy.sh - push the harness to the phone and start an unattended run.
#
#   ./deploy.sh --mode all --reps 20 --batches 3 --seed 1234
#   ./deploy.sh --mode sweep --reps 2 --batches 1 --smoke
#   ./deploy.sh --bench llama-bench-kai --mode counters --out out/run_kai
#   ./deploy.sh --resume --out out/run_kai   # continue a battery-stopped pass
#   ./deploy.sh --status                     # device + run state, changes nothing
#
# adb is used HERE and only here: to copy files and to start the runner
# detached. Once this script returns, adb can die and the run continues.
# Results come back over TCP to receiver.py, not over adb.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEV=/data/local/tmp
MODE=all REPS=20 BATCHES=3 CONTROL_N=8 SEED=1234 TRACE_BATCHES=1
OUTDIR="" NO_MASKED=0 FORCE=0 SMOKE=0 RESUME=0 STATUS=0 FORCE_CLEAR=0
PREP=0 UNPREP=0 SERVE=0
# One run directory = one benchmark implementation. Never mix them: the
# whole point of the A/B is that the two arms are otherwise identical, and a
# directory holding both cannot be told apart after the fact.
BENCH="${BENCH:-llama-bench}"
MASK_MODE="${MASK_MODE:-taskset}"
PC_ADDR="${PC_ADDR:-192.168.0.104 100.100.47.53}"
PC_PORT="${PC_PORT:-9000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       MODE="$2"; shift 2 ;;
    --reps)       REPS="$2"; shift 2 ;;
    --batches)    BATCHES="$2"; shift 2 ;;
    --control-n)  CONTROL_N="$2"; shift 2 ;;
    --seed)       SEED="$2"; shift 2 ;;
    --trace-batches) TRACE_BATCHES="$2"; shift 2 ;;
    --out)        OUTDIR="$2"; shift 2 ;;
    --pc)         PC_ADDR="$2"; shift 2 ;;
    --bench)      BENCH="$2"; shift 2 ;;
    --mask-mode)  MASK_MODE="$2"; shift 2 ;;
    --no-masked)  NO_MASKED=1; shift ;;
    --force)      FORCE=1; shift ;;
    --smoke)      SMOKE=1; shift ;;
    --resume)     RESUME=1; shift ;;
    --status)     STATUS=1; shift ;;
    --serve)      SERVE=1; shift ;;
    --prep)       PREP=1; shift ;;
    --unprep)     UNPREP=1; shift ;;
    --force-clear) FORCE_CLEAR=1; shift ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "deploy: unknown option '$1'" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1m>>\033[0m %s\n' "$*"; }

port_busy() { ss -tln 2>/dev/null | grep -q ":$PC_PORT "; }

start_receiver() {  # $1 = inbox dir, $2 = log file, $3 = pidfile
  nohup python3 "$HERE/receiver.py" --inbox "$1" --port "$PC_PORT" \
        >> "$2" 2>&1 &
  echo $! > "$3"
  sleep 1
  port_busy
}

ensure_receiver_for() {
  # Reusing whatever happens to hold the port is not safe: a listener left
  # over from another run writes arms into ITS inbox, so this run's results
  # would silently land in the wrong directory. Only reuse a receiver this
  # run directory started.
  _dir="$1"
  if port_busy; then
    _pid=$(cat "$_dir/receiver.pid" 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      say "receiver already listening on :$PC_PORT for this run"
      return 0
    fi
    echo "deploy: port $PC_PORT is held by a receiver that is NOT this run's." >&2
    echo "        Arms would land in its inbox, not $_dir/inbox." >&2
    echo "        Stop it first:  kill \$(ss -tlnp | grep :$PC_PORT | grep -oP 'pid=\\K[0-9]+')" >&2
    exit 1
  fi
  start_receiver "$_dir/inbox" "$_dir/receiver.log" "$_dir/receiver.pid" \
    && say "receiver listening on :$PC_PORT -> $_dir/inbox" \
    || { echo "deploy: receiver failed to bind, see $_dir/receiver.log" >&2; exit 1; }
}

# A resume continues an existing dataset, so it must say which one. Without
# this it would silently mint a fresh directory and the resumed arms would
# land somewhere disconnected from the results they belong to.
if [ "$RESUME" = "1" ] && [ -z "$OUTDIR" ]; then
  echo "deploy: --resume needs --out <run directory>" >&2
  echo "        recent runs:" >&2
  ls -1dt "$HERE"/out/*/ 2>/dev/null | head -5 | sed 's/^/          /' >&2
  exit 1
fi

# The implementation is part of the run's identity, so it is in the path.
[ -n "$OUTDIR" ] || OUTDIR="$HERE/out/run_$(date +%Y%m%d_%H%M%S)_$BENCH"
mkdir -p "$OUTDIR/inbox"

# --serve is PC-side only and must work with the phone unreachable - that is
# precisely the situation it exists for.
if [ "$SERVE" != "1" ]; then
  adb get-state >/dev/null 2>&1 || {
    echo "deploy: no adb device. adb connect <ip>:5555" >&2; exit 1; }
fi

# Refuse early if the selected binary cannot run, rather than after the
# thermal gate has already burned ten minutes.
[ "$SERVE" = "1" ] || adb shell "cd $DEV && ./$BENCH --help >/dev/null 2>&1; echo rc=\$?" \
  | tr -d '\r' | grep -q 'rc=0' || {
  echo "deploy: $DEV/$BENCH will not launch (missing? not +x?)" >&2; exit 1; }
for _m in $(echo "$MODE" | tr ',' ' '); do
  case "$_m" in
    all|sweep|counters|control) ;;
    *) echo "deploy: unknown pass '$_m' in --mode" >&2; exit 1 ;;
  esac
done
say "benchmark implementation: $BENCH  (mask mode: $MASK_MODE)"

# A resume must not silently switch implementations underneath an existing
# dataset - that would produce a directory whose arms are not comparable.
if [ "$RESUME" = "1" ] && [ -f "$OUTDIR/manifest.kv" ]; then
  PREV=$(grep '^bench=' "$OUTDIR/manifest.kv" | cut -d= -f2)
  if [ -n "$PREV" ] && [ "$PREV" != "$BENCH" ]; then
    echo "deploy: refusing to mix implementations - $OUTDIR was run with" >&2
    echo "        '$PREV', you asked for '$BENCH'" >&2
    exit 1
  fi
fi

# ------------------------------------------------------------- status

device_state() {
  adb shell 'D=/data/local/tmp
    printf "  battery      : %s%% %s\n" "$(cat $D/../../sys/class/power_supply/battery/capacity 2>/dev/null || cat /sys/class/power_supply/battery/capacity)" "$(cat /sys/class/power_supply/battery/status)"
    printf "  runner       : %s\n" "$([ -d $D/lbench.lock ] && echo "RUNNING (pid $(cat $D/lbench.lock/pid 2>/dev/null))" || echo "not running")"
    printf "  stopped      : %s\n" "$(cat $D/runner.stopped 2>/dev/null || echo no)"
    printf "  progress     : %s\n" "$(cat $D/runner.state 2>/dev/null || echo none)"
    printf "  ledger       : %s arms done\n" "$( [ -f $D/done.ledger ] && wc -l < $D/done.ledger | tr -d " " || echo 0 )"
    printf "  outbox       : %s arms undelivered\n" "$(ls -1 $D/outbox 2>/dev/null | grep -cv "^.staging$")"
    printf "  outbox_bulk  : %s traces (%s)\n" "$(ls -1 $D/outbox_bulk 2>/dev/null | wc -l | tr -d " ")" "$(du -sh $D/outbox_bulk 2>/dev/null | cut -f1)"
  ' 2>/dev/null | tr -d '\r'
}

if [ "$STATUS" = "1" ]; then
  say "device state"
  device_state
  exit 0
fi

# Just listen. Needed after a PC reboot while a run is still going on the
# phone: the run survives, but the arms it finished have nowhere to go until
# something is listening again. Starting a normal deploy would wipe the
# device's plan and ledger, so this exists as its own verb.
if [ "$SERVE" = "1" ]; then
  [ -n "$OUTDIR" ] || { echo "deploy: --serve needs --out <run directory>" >&2
    echo "        recent runs:" >&2
    ls -1dt "$HERE"/out/*/ 2>/dev/null | head -5 | sed 's/^/          /' >&2
    exit 1; }
  mkdir -p "$OUTDIR/inbox"
  ensure_receiver_for "$OUTDIR"
  say "queued arms will drain on the uploader's next cycle (<=15 s)"
  say "build results with: python3 $HERE/ingest.py $OUTDIR --watch"
  exit 0
fi

if [ "$UNPREP" = "1" ]; then
  adb push "$HERE/device/prep.sh" "$HERE/device/lib.sh" "$DEV/" >/dev/null
  adb shell "chmod 755 $DEV/prep.sh; sh $DEV/prep.sh --restore" | tr -d '\r'
  exit 0
fi

if [ "$PREP" = "1" ]; then
  # prep proves the phone can still reach the PC after touching the radios,
  # which requires something to answer. Without this it probed a dead port,
  # concluded the PC was unreachable, and rolled back every time.
  PREP_RECV=""
  if port_busy; then
    say "using the receiver already on :$PC_PORT for the reachability probe"
  else
    PREPDIR="$HERE/out/.prep"; mkdir -p "$PREPDIR/inbox"
    start_receiver "$PREPDIR/inbox" "$PREPDIR/receiver.log" \
                   "$PREPDIR/receiver.pid" \
      || { echo "deploy: could not start a probe receiver" >&2; exit 1; }
    PREP_RECV=$(cat "$PREPDIR/receiver.pid")
    say "started a temporary receiver on :$PC_PORT for the probe"
  fi
  # shellcheck disable=SC2064
  trap "[ -n \"$PREP_RECV\" ] && kill $PREP_RECV 2>/dev/null" EXIT

  say "applying device hygiene (runs on-device so rollback survives WiFi loss)"
  adb push "$HERE/device/prep.sh" "$HERE/device/lib.sh" "$DEV/" >/dev/null
  adb shell "chmod 755 $DEV/prep.sh"
  # Detached: enabling airplane mode may drop this very adb session. The
  # script finishes and self-heals regardless of whether we are still here.
  adb shell "PC_ADDR='$PC_ADDR' PC_PORT=$PC_PORT \
    nohup sh $DEV/prep.sh </dev/null >/dev/null 2>&1 &"
  say "waiting for it to settle (adb may drop and come back)"
  sleep 25
  for _ in $(seq 1 12); do
    adb get-state >/dev/null 2>&1 && break
    sleep 5
  done
  V=$(adb shell "cat $DEV/prep.result 2>/dev/null" | tr -d '\r')
  echo "$V" | sed 's/^/  /'
  echo "$V" | grep -q 'verdict=OK' \
    && say "hygiene applied" \
    || { echo "deploy: prep did not succeed - see above" >&2; exit 1; }
  exit 0
fi

# ------------------------------------------------------------- receiver

ensure_receiver_for "$OUTDIR"

if [ "$RESUME" = "1" ]; then
  say "resume: leaving the on-device plan and ledger alone"
else
  # ------------------------------------------------------------- plan
  PLANARGS=(--mode "$MODE" --reps "$REPS" --batches "$BATCHES"
            --control-n "$CONTROL_N" --seed "$SEED"
            --trace-batches "$TRACE_BATCHES" -o "$OUTDIR/plan.tsv")
  [ "$NO_MASKED" = "1" ] && PLANARGS+=(--no-masked)
  say "generating plan"
  python3 "$HERE/plan.py" "${PLANARGS[@]}" || exit 1

  if [ "$SMOKE" = "1" ]; then
    head -1 "$OUTDIR/plan.tsv" > "$OUTDIR/plan.smoke"
    grep -v '^#' "$OUTDIR/plan.tsv" | head -4 >> "$OUTDIR/plan.smoke"
    mv "$OUTDIR/plan.smoke" "$OUTDIR/plan.tsv"
    say "smoke mode: trimmed to $(grep -cv '^#' "$OUTDIR/plan.tsv") arms"
  fi
fi

# ------------------------------------------------------------- push

say "pushing scripts"
adb push "$HERE/device/lib.sh" "$HERE/device/runner.sh" \
         "$HERE/device/uploader.sh" "$HERE/device/preflight.sh" \
         "$HERE/device/sampler.sh" "$HERE/device/trace_config.pbtx" \
         "$DEV/" >/dev/null || exit 1
[ "$RESUME" = "1" ] || adb push "$OUTDIR/plan.tsv" "$DEV/plan.tsv" >/dev/null
adb shell "chmod 755 $DEV/lib.sh $DEV/runner.sh $DEV/uploader.sh \
                     $DEV/preflight.sh $DEV/sampler.sh"

# The plan must arrive intact: a truncated push would silently shorten the
# matrix, and the device has no way to know what it should have received.
if [ "$RESUME" != "1" ]; then
  LOC=$(sha256sum "$OUTDIR/plan.tsv" | cut -d' ' -f1)
  REM=$(adb shell "sha256sum $DEV/plan.tsv" | tr -d '\r' | cut -d' ' -f1)
  [ "$LOC" = "$REM" ] && say "plan checksum verified" \
    || { echo "deploy: plan.tsv checksum mismatch after push" >&2; exit 1; }
fi

if [ "$RESUME" != "1" ]; then
  # Starting a new pass wipes the device's run state - including the outbox.
  # If the previous session ended with arms still queued (battery died before
  # they drained, PC was unreachable), clearing would destroy measurements
  # that exist nowhere else. Refuse instead.
  PENDING=$(adb shell "ls -1 $DEV/outbox 2>/dev/null | grep -cv '^\.staging$'" \
            | tr -d '\r')
  PENDING=${PENDING:-0}
  if [ "$PENDING" -gt 0 ] && [ "$FORCE_CLEAR" != "1" ]; then
    echo "deploy: $PENDING undelivered arm(s) still on the device." >&2
    echo "        Starting a new pass would delete them." >&2
    echo "        Let them drain first (the receiver is now listening):" >&2
    echo "          adb shell 'BENCH=$BENCH nohup sh $DEV/uploader.sh </dev/null >/dev/null 2>&1 &'" >&2
    echo "          ./deploy.sh --status" >&2
    echo "        Or discard them deliberately with --force-clear." >&2
    exit 1
  fi
  say "clearing previous run state on device"
  adb shell "rm -rf $DEV/outbox $DEV/outbox_bulk $DEV/done.ledger \
                    $DEV/runner.done $DEV/runner.stopped $DEV/lbench.lock \
                    $DEV/.requeue $DEV/.pids"
else
  # Resuming keeps the plan and the ledger, but a stale stop marker would
  # make the runner exit again immediately after the first arm.
  say "resume: clearing stop marker, keeping plan and ledger"
  adb shell "rm -f $DEV/runner.stopped $DEV/runner.done; rm -rf $DEV/lbench.lock"
fi

# Record what this directory is, so ingest and a later resume agree.
{
  echo "bench=$BENCH"
  echo "mask_mode=$MASK_MODE"
  echo "seed=$SEED"
  echo "mode=$MODE"
  echo "reps=$REPS"
  echo "batches=$BATCHES"
  echo "control_n=$CONTROL_N"
  echo "deployed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "bench_sha1=$(adb shell "sha1sum $DEV/$BENCH" | tr -d '\r' | cut -d' ' -f1)"
  echo "model_sha1=$(adb shell "sha1sum $DEV/model.gguf" | tr -d '\r' | cut -d' ' -f1)"
} > "$OUTDIR/manifest.kv"

# ------------------------------------------------------------- launch

say "starting runner detached (adb is no longer needed after this)"
# NO `cd X && ... &` here. Backgrounding a compound list inside an adb shell
# string keeps a copy of the adb pipe open and hangs this call forever. That
# is SETUP_LOG crash #4c, rediscovered by writing it again. Absolute paths,
# env prefix instead of cd, nohup, and all three fds redirected.
adb shell "PC_ADDR='$PC_ADDR' PC_PORT=$PC_PORT FORCE=$FORCE \
  BENCH=$BENCH MASK_MODE=$MASK_MODE \
  nohup sh $DEV/runner.sh $DEV/plan.tsv </dev/null >/dev/null 2>&1 &"
sleep 3

RPID=$(adb shell "cat $DEV/lbench.lock/pid 2>/dev/null" | tr -d '\r')
if [ -n "$RPID" ]; then
  say "runner is up (device pid $RPID)"
else
  echo "deploy: runner did not take the lock - check $DEV/runner.log" >&2
  adb shell "tail -20 $DEV/runner.log" | tr -d '\r'
  exit 1
fi

cat <<EOF

  implementation: $BENCH  (mask mode: $MASK_MODE)
  run directory : $OUTDIR
  receiver      : :$PC_PORT  -> $OUTDIR/inbox
  device pid    : $RPID

  adb is now optional. To watch progress:
      tail -f $OUTDIR/receiver.log
      cat $OUTDIR/inbox/.heartbeat
  To build results as arms arrive:
      python3 $HERE/ingest.py $OUTDIR --watch
  Then:
      python3 $HERE/analyze.py $OUTDIR
EOF
