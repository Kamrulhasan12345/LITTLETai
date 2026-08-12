#!/bin/sh
# Stub sampler: emits a telemetry CSV at a controllable cadence. If
# $DEV/.stub_sampler_gap holds a number, one inter-sample gap of that many
# seconds is injected - which is how the suspend-detection path is tested.
IVAL_MS=${1:-200}; OUT=${2:-/tmp/telemetry.csv}
DEV="${DEV:-/data/local/tmp}"
GAP=$(cat "$DEV/.stub_sampler_gap" 2>/dev/null || echo 0)
echo "boottime_s,policy0_khz,policy6_khz,current_now,voltage_now,charge_counter" > "$OUT"
read -r NOW _ < /proc/uptime
i=0
while [ "$i" -lt 400 ]; do
  echo "$NOW,850000,850000,300,4000,$((3000000 - i))" >> "$OUT"
  NOW=$(awk "BEGIN{printf \"%.2f\", $NOW + 0.2}")
  if [ "$i" = "3" ] && [ "$GAP" != "0" ]; then
    NOW=$(awk "BEGIN{printf \"%.2f\", $NOW + $GAP}")
  fi
  i=$((i + 1))
  sleep 0.02
done
