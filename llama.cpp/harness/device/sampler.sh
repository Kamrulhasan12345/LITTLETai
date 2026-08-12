#!/system/bin/sh
# sampler.sh - runs ON the device. One process, one loop, sysfs reads only.
#
# Deliberately avoids dumpsys in the loop: dumpsys is a binder round-trip into
# system_server and wakes an entire other process every tick. Direct sysfs
# reads are a cheap VFS path.
#
#   sh sampler.sh <interval_ms> <out.csv> <zone_list_file>
#
# Columns: boottime_s, then one column per cpufreq policy, then one per zone,
# then battery current/voltage/charge.
# Timestamps are CLOCK_BOOTTIME (from /proc/uptime) to match ftrace.

IVAL_MS=${1:-200}
OUT=${2:-/data/local/tmp/telemetry.csv}
ZONES_F=${3:-/data/local/tmp/zones.txt}

# Resolve what to read ONCE, outside the loop.
POLICIES=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
ZONES=$(cat "$ZONES_F" 2>/dev/null)
BAT=/sys/class/power_supply/battery

# Header
H="boottime_s"
for p in $POLICIES; do H="$H,$(basename "$p")_khz"; done
for z in $ZONES;    do H="$H,$(basename "$z")_mC"; done
H="$H,current_now,voltage_now,charge_counter"
echo "$H" > "$OUT"

# toybox sleep accepts fractional seconds
IVAL=$(awk "BEGIN{printf \"%.3f\", $IVAL_MS/1000}")

while :; do
  # /proc/uptime field 1 is seconds since boot = CLOCK_BOOTTIME
  set -- $(cat /proc/uptime)
  LINE="$1"
  for p in $POLICIES; do
    v=$(cat "$p/scaling_cur_freq" 2>/dev/null); LINE="$LINE,${v:-}"
  done
  for z in $ZONES; do
    v=$(cat "$z/temp" 2>/dev/null); LINE="$LINE,${v:-}"
  done
  i=$(cat $BAT/current_now 2>/dev/null)
  u=$(cat $BAT/voltage_now 2>/dev/null)
  c=$(cat $BAT/charge_counter 2>/dev/null)
  echo "$LINE,${i:-},${u:-},${c:-}" >> "$OUT"
  sleep "$IVAL"
done
