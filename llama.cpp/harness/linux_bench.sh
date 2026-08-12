#!/usr/bin/env bash
# linux_bench.sh - same methodology on the Pi Zero 2 W / x86 laptop, where you
# HAVE root and can pin frequency. This is your clean reference platform:
# no DVFS noise, no cgroup weirdness, full kernel-mode PMU counting.
#
#   sudo ./linux_bench.sh -m model.gguf -b ./llama-bench -r 20
#
# Differences from the Android path, by design:
#   - governor pinned to `performance`, so thermal/DVFS is not a confound
#   - no ":u" restriction: counts include kernel mode
#   - perf instead of simpleperf; event names differ per arch

set -euo pipefail
MODEL=model.gguf; BENCH=./llama-bench; REPS=20; NGEN=128; NPROMPT=512
OUT="out_linux_$(date +%Y%m%d_%H%M%S)"; THREADS="1 2 4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) MODEL="$2"; shift 2 ;;
    -b) BENCH="$2"; shift 2 ;;
    -r) REPS="$2"; shift 2 ;;
    -t) THREADS="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$OUT"

ARCH=$(uname -m)
if [[ "$ARCH" == aarch64* || "$ARCH" == arm* ]]; then
  EVENTS="cycles,instructions,stalled-cycles-backend,cache-misses,L1-dcache-load-misses"
else
  EVENTS="cycles,instructions,cache-misses,LLC-load-misses,stalled-cycles-backend"
fi

echo "== environment =="
{ echo "date: $(date -Is)"; echo "arch: $ARCH"; echo "kernel: $(uname -r)";
  echo "model_sha1: $(sha1sum "$MODEL" | cut -d' ' -f1)";
  echo "bench_sha1: $(sha1sum "$BENCH" | cut -d' ' -f1)";
  lscpu 2>/dev/null | sed -n '1,25p'; } | tee "$OUT/manifest.txt"

# Pin frequency - the whole point of using this platform as the reference.
if [[ $EUID -eq 0 ]]; then
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w $g ]] && echo performance > "$g" || true
  done
  echo "governor -> performance"
  echo -1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
else
  echo "WARN: not root - frequency not pinned, results will carry DVFS noise"
fi

cool() {
  local z=/sys/class/thermal/thermal_zone0/temp
  sleep 30
  [[ -r $z ]] || return 0
  while (( $(cat $z) > 55000 )); do
    printf '\r  cooling: %s C   ' "$(( $(cat $z) / 1000 ))"; sleep 10
  done; printf '\r%*s\r' 30 ''
}

for t in $THREADS; do
  for test in tg pp; do
    tag="${test}_t${t}"
    [[ "$test" == tg ]] && shape="-p 0 -n $NGEN" || shape="-p $NPROMPT -n 0"
    echo "== $tag =="
    cool
    "$BENCH" -m "$MODEL" $shape -t "$t" -r "$REPS" -o json > "$OUT/$tag.json"
    cool
    perf stat -e "$EVENTS" -x, -o "$OUT/$tag.perf.csv" -- \
      "$BENCH" -m "$MODEL" $shape -t "$t" -r 5 >/dev/null 2>&1 || \
      echo "  perf failed (check perf_event_paranoid)"
    echo "  $(python3 - "$OUT/$tag.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
v=sorted(x["avg_ts"] for x in d)
print(f"median {v[len(v)//2]:.2f} t/s  min {v[0]:.2f}  max {v[-1]:.2f}")
PY
)"
  done
done
echo "done -> $OUT"
