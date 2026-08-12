#!/usr/bin/env bash
# test_runner.sh - scenario tests for the on-device loop, run on the LAPTOP.
#
#   ./test_runner.sh            # all scenarios
#   ./test_runner.sh lock       # only scenarios whose name matches
#
# runner.sh is POSIX sh driven entirely by $DEV, $PATH and $BAT_DIR, so the
# whole loop runs here against a fake device tree with stub binaries. This is
# the gate before anything touches the phone: a 16 h unattended run is the
# worst possible place to discover that a failure path was never exercised.
#
# The tests assert on OBSERVABLE OUTCOMES - what landed in the outbox, what
# meta.kv says, whether the ledger allows a resume - not on log text.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"
PASS=0; FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ harness

setup() {
  DEV=$(mktemp -d /tmp/lbench_test.XXXXXX)
  export DEV
  export BAT_DIR="$DEV/battery"
  export TRACE_DIR="$DEV/traces"
  export CFG_DIR="$DEV/cfgs"
  export THERMAL_DIR="$DEV/thermal"   # empty -> temp comes from the dumpsys stub
  export PATH="$HERE/stubs:$PATH"
  export BENCH_TIMEOUT=5
  export TRACE_FREE_MB=1        # /tmp is smaller than a phone; do not skip traces
  export MIN_FREE_MB=1
  export COOL_MIN_S=0
  export COOL_MAX_WAIT_S=2
  # The stub tree cannot satisfy the pinning or frequency gates - they probe
  # real hardware. Preflight is exercised separately, against the device.
  export SKIP_PREFLIGHT=1
  mkdir -p "$BAT_DIR" "$TRACE_DIR" "$CFG_DIR" "$THERMAL_DIR"
  echo Discharging > "$BAT_DIR/status"
  echo 90          > "$BAT_DIR/capacity"
  echo 3000000     > "$BAT_DIR/charge_counter"
  echo 300         > "$BAT_DIR/current_now"
  echo 4000        > "$BAT_DIR/voltage_now"
  cp "$HERE/stubs/llama-bench" "$DEV/llama-bench"
  cp "$HERE/stubs/sampler.sh"  "$DEV/sampler.sh"
  : > "$DEV/model.gguf"
}

teardown() { [ -n "${DEV:-}" ] && rm -rf "$DEV"; }

# one-arm plan; $1 overrides the telemetry flag, $2 the trace flag
plan_one() {
  printf '#header\n' > "$DEV/plan.tsv"
  printf 'sweep.tg_t6_free.b0\tsweep\ttg_t6_free\t6\tfree\ttg\t20\t0\t0\t128\t%s\t%s\t-\t-\n' \
    "${1:-0}" "${2:-0}" >> "$DEV/plan.tsv"
}

run_runner() { sh "$HERE/runner.sh" "$DEV/plan.tsv" >/dev/null 2>&1; }

meta() { grep "^$2=" "$DEV/outbox/$1/meta.kv" 2>/dev/null | cut -d= -f2-; }

should_run() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- scenarios

t_happy_path() {
  setup; plan_one 1 0; run_runner
  [ -f "$DEV/outbox/sweep.tg_t6_free.b0/bench.json" ] \
    && ok "happy: bench.json committed" || bad "happy: no bench.json"
  [ -f "$DEV/outbox/sweep.tg_t6_free.b0/meta.kv" ] \
    && ok "happy: meta.kv committed" || bad "happy: no meta.kv"
  [ "$(meta sweep.tg_t6_free.b0 rc)" = "0" ] \
    && ok "happy: rc=0" || bad "happy: rc=$(meta sweep.tg_t6_free.b0 rc)"
  [ "$(meta sweep.tg_t6_free.b0 suspend_detected)" = "0" ] \
    && ok "happy: no suspend" || bad "happy: spurious suspend"
  grep -q 'sweep.tg_t6_free.b0' "$DEV/done.ledger" \
    && ok "happy: ledger updated" || bad "happy: ledger not updated"
  [ -n "$(meta sweep.tg_t6_free.b0 attempt_id)" ] \
    && ok "happy: attempt_id recorded" || bad "happy: no attempt_id"
  [ -n "$(meta sweep.tg_t6_free.b0 boot_id)" ] \
    && ok "happy: boot_id recorded" || bad "happy: no boot_id"
  teardown
}

t_bench_nonzero_rc() {
  setup; plan_one 0 0; echo 3 > "$DEV/.stub_bench_rc"; run_runner
  [ "$(meta sweep.tg_t6_free.b0 rc)" = "3" ] \
    && ok "rc: nonzero exit recorded" || bad "rc: not recorded"
  # a definite failure is safe to re-queue, and re-queuing removes it from
  # the ledger so the next pass can run it
  ! grep -q 'sweep.tg_t6_free.b0' "$DEV/done.ledger" 2>/dev/null \
    && ok "rc: failed arm dropped from ledger for re-queue" \
    || bad "rc: failed arm still in ledger"
  teardown
}

t_bench_hang_times_out() {
  setup; plan_one 0 0; : > "$DEV/.stub_bench_hang"
  start=$(date +%s); run_runner; el=$(( $(date +%s) - start ))
  [ "$el" -lt 30 ] \
    && ok "hang: killed by timeout after ${el}s" || bad "hang: took ${el}s"
  [ "$(meta sweep.tg_t6_free.b0 timed_out)" = "1" ] \
    && ok "hang: timed_out=1 recorded" || bad "hang: timed_out not set"
  teardown
}

t_json_failure_modes() {
  for mode in empty invalid norows; do
    setup; plan_one 0 0; echo "$mode" > "$DEV/.stub_bench_out"; run_runner
    case "$mode" in
      empty) [ ! -f "$DEV/outbox/sweep.tg_t6_free.b0/bench.json" ] \
               && ok "json/$mode: no bench.json committed" \
               || bad "json/$mode: bench.json should not exist" ;;
      *)     [ -f "$DEV/outbox/sweep.tg_t6_free.b0/bench.json" ] \
               && ok "json/$mode: malformed json still shipped for the PC to judge" \
               || bad "json/$mode: not shipped" ;;
    esac
    teardown
  done
}

t_thermal_gate() {
  setup; plan_one 0 0
  echo 99.0 > "$DEV/.stub_temp_c"          # far above the 42C gate
  run_runner
  [ "$(meta sweep.tg_t6_free.b0 cool_timeout)" = "1" ] \
    && ok "thermal: gate timed out and was recorded" || bad "thermal: not recorded"
  [ ! -f "$DEV/outbox/sweep.tg_t6_free.b0/bench.json" ] \
    && ok "thermal: hot bench never ran" || bad "thermal: ran a hot bench"
  teardown
}

t_suspend_detection() {
  setup; plan_one 1 0
  echo 2 > "$DEV/.stub_bench_delay"        # give the sampler a live window
  echo 120 > "$DEV/.stub_sampler_gap"      # inject a 120 s freeze
  run_runner
  [ "$(meta sweep.tg_t6_free.b0 suspend_detected)" = "1" ] \
    && ok "suspend: 120s gap detected" || bad "suspend: gap missed"
  teardown
}

t_suspend_ignores_jitter() {
  setup; plan_one 1 0
  echo 2 > "$DEV/.stub_bench_delay"        # same window, ordinary jitter
  echo 4.4 > "$DEV/.stub_sampler_gap"      # worst legitimate gap ever measured
  run_runner
  [ "$(meta sweep.tg_t6_free.b0 suspend_detected)" = "0" ] \
    && ok "suspend: 4.4s jitter not treated as a suspend" \
    || bad "suspend: false positive on jitter"
  teardown
}

t_double_start_lock() {
  setup; plan_one 0 0
  mkdir -p "$DEV/lbench.lock"; echo $$ > "$DEV/lbench.lock/pid"   # live pid
  run_runner
  [ ! -d "$DEV/outbox/sweep.tg_t6_free.b0" ] \
    && ok "lock: second runner refused to start" \
    || bad "lock: second runner ran anyway"
  teardown
}

t_stale_lock_reclaimed() {
  setup; plan_one 0 0
  mkdir -p "$DEV/lbench.lock"; echo 999999 > "$DEV/lbench.lock/pid"  # dead
  run_runner
  [ -d "$DEV/outbox/sweep.tg_t6_free.b0" ] \
    && ok "lock: stale lock reclaimed" || bad "lock: stale lock blocked the run"
  teardown
}

t_resume_skips_done() {
  setup; plan_one 0 0
  echo 'sweep.tg_t6_free.b0' > "$DEV/done.ledger"
  run_runner
  [ ! -d "$DEV/outbox/sweep.tg_t6_free.b0" ] \
    && ok "resume: finished arm not re-run" || bad "resume: re-ran a finished arm"
  teardown
}

t_battery_stop() {
  setup; plan_one 0 0; echo 5 > "$BAT_DIR/capacity"     # below the 15% floor
  run_runner
  [ -f "$DEV/runner.stopped" ] && [ "$(cat "$DEV/runner.stopped")" = "battery" ] \
    && ok "battery: stopped cleanly with a reason" || bad "battery: did not stop"
  [ ! -d "$DEV/outbox/sweep.tg_t6_free.b0" ] \
    && ok "battery: no arm run on a flat battery" || bad "battery: ran anyway"
  teardown
}

t_charging_recorded() {
  setup; plan_one 0 0; echo Charging > "$BAT_DIR/status"; run_runner
  [ "$(meta sweep.tg_t6_free.b0 battery_status_start)" = "Charging" ] \
    && ok "charging: recorded so the PC can void energy" \
    || bad "charging: not recorded"
  teardown
}

t_atomic_commit() {
  # Nothing partially written may ever appear in the outbox: the uploader
  # scans it concurrently and would ship a half-built arm.
  setup; plan_one 1 0; run_runner
  [ -z "$(ls -A "$DEV/outbox/.staging" 2>/dev/null)" ] \
    && ok "atomic: staging drained" || bad "atomic: staging left behind"
  for d in "$DEV"/outbox/*/; do
    [ "$(basename "$d")" = ".staging" ] && continue
    [ -f "$d/meta.kv" ] || bad "atomic: $d committed without meta.kv"
  done
  ok "atomic: every committed arm has meta.kv"
  teardown
}

t_trace_goes_to_bulk_queue() {
  setup; plan_one 1 1; run_runner
  [ -d "$DEV/outbox_bulk/sweep.tg_t6_free.b0.trace" ] \
    && ok "trace: landed in the bulk queue" || bad "trace: not in bulk queue"
  [ ! -f "$DEV/outbox/sweep.tg_t6_free.b0/trace.perfetto-trace" ] \
    && ok "trace: kept out of the priority queue" \
    || bad "trace: polluting the priority queue"
  [ -f "$DEV/outbox/sweep.tg_t6_free.b0/bench.json" ] \
    && ok "trace: measurement still delivered separately" \
    || bad "trace: measurement missing"
  teardown
}

t_counters_arm() {
  setup
  printf '#h\n' > "$DEV/plan.tsv"
  printf 'counters.tg_t6_free.core\tcounters\ttg_t6_free\t6\tfree\ttg\t10\t0\t0\t128\t0\t0\tcpu-cycles:u,instructions:u\tcore\n' \
    >> "$DEV/plan.tsv"
  run_runner
  [ -f "$DEV/outbox/counters.tg_t6_free.core/perf.txt" ] \
    && ok "counters: perf.txt committed" || bad "counters: no perf.txt"
  grep -q 'cpu-cycles:u' "$DEV/outbox/counters.tg_t6_free.core/perf.txt" 2>/dev/null \
    && ok "counters: report has events" || bad "counters: empty report"
  [ -f "$DEV/outbox/counters.tg_t6_free.core/bench.json" ] \
    && ok "counters: workload json also captured" || bad "counters: no bench.json"
  teardown
}

t_orphans_reaped() {
  setup; plan_one 1 0
  sleep 120 >/dev/null 2>&1 &
  orphan=$!
  echo "$orphan" > "$DEV/.pids"        # as a crashed predecessor would leave it
  run_runner
  ! kill -0 "$orphan" 2>/dev/null \
    && ok "orphans: stale sampler reaped before the arm" \
    || { bad "orphans: stale sampler survived"; kill "$orphan" 2>/dev/null; }
  teardown
}

t_multi_arm_order_preserved() {
  setup
  printf '#h\n' > "$DEV/plan.tsv"
  for i in 0 1 2; do
    printf 'sweep.c%s.b0\tsweep\tc%s\t6\tfree\ttg\t2\t0\t0\t128\t0\t0\t-\t-\n' \
      "$i" "$i" >> "$DEV/plan.tsv"
  done
  run_runner
  n=$(ls -d "$DEV"/outbox/sweep.c*.b0 2>/dev/null | wc -l)
  [ "$n" = "3" ] && ok "multi: all 3 arms committed" || bad "multi: only $n arms"
  [ "$(head -1 "$DEV/done.ledger")" = "sweep.c0.b0" ] \
    && ok "multi: plan order honoured" || bad "multi: order not preserved"
  teardown
}

# --------------------------------------------------------------------- main

hdr "device runner scenarios"
for t in t_happy_path t_bench_nonzero_rc t_bench_hang_times_out \
         t_json_failure_modes t_thermal_gate t_suspend_detection \
         t_suspend_ignores_jitter t_double_start_lock t_stale_lock_reclaimed \
         t_resume_skips_done t_battery_stop t_charging_recorded \
         t_atomic_commit t_trace_goes_to_bulk_queue t_counters_arm \
         t_orphans_reaped t_multi_arm_order_preserved; do
  should_run "$t" && $t
done

hdr "summary"
printf '  pass=%d  fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
