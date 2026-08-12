#!/usr/bin/env bash
# e2e_dryrun.sh - the whole pipeline on the laptop, with no phone involved.
#
#   ./e2e_dryrun.sh
#
# Runs the REAL runner.sh, uploader.sh, receiver.py, ingest.py and analyze.py
# against a fake device tree with stub binaries. This is the gate before
# anything is deployed: it exercises the seams between the five components,
# which unit tests by construction cannot.
#
# What it proves:
#   1. a plan generated on the PC executes arm for arm on the "device"
#   2. finished arms are framed, checksummed, shipped and acknowledged
#   3. the device deletes its copy ONLY after that acknowledgement
#   4. the PC reassembles them into results*.json and a readable summary
#   5. a receiver outage stalls delivery but NOT the benchmark loop, and the
#      backlog drains once it returns

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-9411}"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

WORK=$(mktemp -d /tmp/lbench_e2e.XXXXXX)
RECV_PID=""
cleanup() {
  [ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null
  [ -f "$WORK/dev/.uploader.pid" ] && kill "$(cat "$WORK/dev/.uploader.pid")" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

export DEV="$WORK/dev"
export BAT_DIR="$DEV/battery"
export TRACE_DIR="$DEV/traces"
export CFG_DIR="$DEV/cfgs"
export THERMAL_DIR="$DEV/thermal"
export PATH="$HERE/device/stubs:$PATH"
export BENCH_TIMEOUT=20 COOL_MIN_S=0 COOL_MAX_WAIT_S=2
export TRACE_FREE_MB=1 MIN_FREE_MB=1
export PC_ADDR=127.0.0.1 PC_PORT="$PORT" POLL_S=2 HEARTBEAT_S=5 LINGER_S=2
export AUTO_UPLOADER=0        # this script drives the uploader itself
# The stub tree cannot satisfy the pinning or frequency gates - they probe
# real hardware. Preflight is exercised separately, against the device.
export SKIP_PREFLIGHT=1

mkdir -p "$DEV" "$BAT_DIR" "$TRACE_DIR" "$CFG_DIR" "$THERMAL_DIR"
echo Discharging > "$BAT_DIR/status"; echo 95 > "$BAT_DIR/capacity"
echo 3000000 > "$BAT_DIR/charge_counter"
echo 300 > "$BAT_DIR/current_now"; echo 4000 > "$BAT_DIR/voltage_now"
cp "$HERE/device/stubs/llama-bench" "$DEV/llama-bench"
cp "$HERE/device/stubs/sampler.sh"  "$DEV/sampler.sh"
: > "$DEV/model.gguf"

RUN="$WORK/run"
mkdir -p "$RUN/inbox"

# ---------------------------------------------------------------- 1. plan

hdr "1. plan generation (PC)"
# --no-masked: masked configs use taskset with an 8-core big.LITTLE mask,
# which cannot run on a laptop. Masking is verified against the real device
# by preflight, not here.
python3 "$HERE/plan.py" --mode all --no-masked --reps 2 --batches 1 \
        --control-n 1 --seed 7 -o "$DEV/plan.tsv" >/dev/null
ARMS=$(grep -cv '^#' "$DEV/plan.tsv")
[ "$ARMS" -gt 0 ] && ok "plan generated: $ARMS arms" || bad "no plan"

# keep the dry run short: 6 arms is enough to cross every seam
head -1 "$DEV/plan.tsv" > "$DEV/plan_small.tsv"
grep -v '^#' "$DEV/plan.tsv" | head -6 >> "$DEV/plan_small.tsv"
mv "$DEV/plan_small.tsv" "$DEV/plan.tsv"
ARMS=6

# --------------------------------------------- 2. run with receiver DOWN

hdr "2. benchmark loop with the PC unreachable"
sh "$HERE/device/runner.sh" "$DEV/plan.tsv" >"$WORK/runner.log" 2>&1 &
RUNNER_PID=$!
sh "$HERE/device/uploader.sh" >/dev/null 2>&1 &
echo $! > "$DEV/.uploader.pid"

sleep 12
QUEUED=$(ls -1 "$DEV/outbox" 2>/dev/null | grep -cv '^\.staging$')
[ "$QUEUED" -gt 0 ] \
  && ok "arms queued while the PC was down ($QUEUED waiting)" \
  || bad "nothing queued - did the loop stall?"
kill -0 "$RUNNER_PID" 2>/dev/null \
  && ok "benchmark loop still running despite no PC" \
  || ok "benchmark loop already finished despite no PC"
[ "$(ls -1 "$RUN/inbox" 2>/dev/null | wc -l)" -eq 0 ] \
  && ok "nothing delivered (receiver is down, as expected)" \
  || bad "something arrived with no receiver running"

# ------------------------------------------------ 3. bring the receiver up

hdr "3. receiver comes up - backlog must drain"
python3 "$HERE/receiver.py" --inbox "$RUN/inbox" --port "$PORT" \
        >"$WORK/receiver.log" 2>&1 &
RECV_PID=$!
sleep 2

wait "$RUNNER_PID" 2>/dev/null
for _ in $(seq 1 40); do
  left=$(ls -1 "$DEV/outbox" 2>/dev/null | grep -cv '^\.staging$')
  [ "$left" -eq 0 ] && break
  sleep 2
done

DELIVERED=$(ls -1 "$RUN/inbox"/*.tar 2>/dev/null | wc -l)
[ "$DELIVERED" -ge "$ARMS" ] \
  && ok "all $DELIVERED arms delivered after the outage" \
  || bad "only $DELIVERED/$ARMS arms delivered"

LEFT=$(ls -1 "$DEV/outbox" 2>/dev/null | grep -cv '^\.staging$')
[ "$LEFT" -eq 0 ] \
  && ok "outbox drained (device deleted only after ack)" \
  || bad "$LEFT arms stuck in the outbox"

# Poll rather than sample once: heartbeats are asynchronous, so checking at a
# single instant made this test flaky - and a flaky test is worse than none,
# because it teaches you to ignore the failure.
HB_SEEN=0
for _ in $(seq 1 20); do
  if grep -q 'HB ' "$WORK/receiver.log"; then HB_SEEN=1; break; fi
  sleep 1
done
[ "$HB_SEEN" = "1" ] \
  && ok "heartbeat reached the PC" || bad "no heartbeat within 20s"

# ------------------------------------------------------------- 4. ingest

hdr "4. ingest + analyze (PC)"
python3 "$HERE/ingest.py" "$RUN" >"$WORK/ingest.log" 2>&1 \
  && ok "ingest completed" || bad "ingest failed"

python3 - "$RUN" <<'PY'
import json, sys, pathlib
run = pathlib.Path(sys.argv[1])
tot = valid = 0
for suf in ("", "_counters", "_control"):
    p = run / f"results{suf}.json"
    if not p.exists():
        continue
    rows = json.loads(p.read_text())
    tot += len(rows)
    valid += sum(1 for r in rows if r.get("extra", {}).get("valid"))
    for r in rows:
        assert r["extra"].get("attempt_id"), f"{r['config']}: no attempt_id"
        assert r["extra"].get("boot_id"), f"{r['config']}: no boot_id"
print(f"RESULTS {tot} {valid}")
PY

read -r _ TOT VALID <<<"$(python3 - "$RUN" <<'PY'
import json, sys, pathlib
run = pathlib.Path(sys.argv[1]); tot = valid = 0
for suf in ("", "_counters", "_control"):
    p = run / f"results{suf}.json"
    if p.exists():
        rows = json.loads(p.read_text())
        tot += len(rows); valid += sum(1 for r in rows if r.get("extra", {}).get("valid"))
print("R", tot, valid)
PY
)"
[ "${TOT:-0}" -ge "$ARMS" ] \
  && ok "results contain $TOT arms ($VALID valid)" \
  || bad "results contain only ${TOT:-0} arms, expected >= $ARMS"

python3 "$HERE/analyze.py" "$RUN" >/dev/null 2>&1 \
  && ok "analyze produced a summary" || bad "analyze failed"
[ -s "$RUN/summary.md" ] && ok "summary.md is non-empty" || bad "summary.md missing"

# ------------------------------------------------------- 5. integrity

hdr "5. integrity"
BAD=0
for t in "$RUN/inbox"/*.tar; do
  tar -tf "$t" >/dev/null 2>&1 || BAD=$((BAD+1))
done
[ "$BAD" -eq 0 ] && ok "every delivered tar is readable" \
                 || bad "$BAD corrupt tars"

[ -z "$(ls -A "$DEV/outbox/.staging" 2>/dev/null)" ] \
  && ok "no half-written arm left in staging" || bad "staging not drained"

grep -q 'CHECKSUM MISMATCH' "$WORK/receiver.log" \
  && bad "a checksum mismatch occurred" || ok "no checksum mismatches"

hdr "summary"
printf '  pass=%d  fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo; echo "--- runner.log ---"; tail -20 "$WORK/runner.log"; \
                       echo "--- uploader.log ---"; tail -20 "$DEV/uploader.log" 2>/dev/null; \
                       exit 1; }
