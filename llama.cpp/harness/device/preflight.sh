#!/system/bin/sh
# preflight.sh - validate the apparatus BEFORE committing 16 hours to it.
#
#   sh preflight.sh [--bench llama-bench]
#
# Runs on the device, writes $DEV/preflight.kv, exits non-zero if any gate
# fails. runner.sh refuses to start the matrix on a failure unless FORCE=1.
#
# Two of these gates exist because the previous dataset was invalidated by
# faults the apparatus never reported:
#
#   PINNING    Four of eleven configs exist only to compare A55 against A75,
#              and they are selected with `-C <mask> --cpu-strict 1`. In the
#              historical Pass B data, tg_t2_A55 (mask 0x03, i.e. two little
#              cores) put 97.2% of its cycles on cpu6/cpu7 - identical to the
#              unmasked run. The mask did nothing, and nothing said so.
#
#   FREQUENCY  policy6_khz read a constant 850000 across all 26,417 telemetry
#              samples of the 33-arm sweep. analyze.py flags throttling as
#              "fraction of samples below 90% of the observed ceiling", and a
#              constant series has no such samples - so "0/3 throttled" was a
#              property of the detector, not of the device.
#
# Both are cheap to check and expensive to discover afterwards.

set -u

HERE=$(dirname "$0")
. "$HERE/lib.sh"

BENCH="${BENCH:-llama-bench}"
MASK_MODE="${MASK_MODE:-taskset}"
MODEL="${MODEL:-model.gguf}"
PROBE_N="${PROBE_N:-32}"          # short: this is a gate, not a measurement
# Generous: the FIRST llama-bench of a session pages a 429 MB model in from
# storage, which is far slower than any subsequent run. A timeout here leaves
# a truncated simpleperf report that looks like "no cycles were counted".
PROBE_TIMEOUT="${PROBE_TIMEOUT:-900}"
PIN_MAX_BIG_PCT="${PIN_MAX_BIG_PCT:-5}"
OUT="$DEV/preflight.kv"

PASS=0; FAIL=0; WARN=0
pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }
kv()   { echo "$1=$2" >> "$OUT"; }

: > "$OUT"
kv preflight_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
kv boot_id "$(boot_id)"

echo "== device =="
kv model_name "$(getprop ro.product.model 2>/dev/null)"
kv soc "$(getprop ro.board.platform 2>/dev/null)"
kv android "$(getprop ro.build.version.release 2>/dev/null)"
kv kernel "$(uname -r)"
echo "  $(getprop ro.product.model 2>/dev/null) / $(getprop ro.board.platform 2>/dev/null) / $(uname -r)"

# ------------------------------------------------------------ 1. binaries

echo "== binaries =="
if [ -f "$DEV/$BENCH" ]; then
  pass "$BENCH present"
else
  fail "$BENCH missing from $DEV"
fi
( cd "$DEV" && ./"$BENCH" --help >/dev/null 2>&1 )
if [ $? -eq 0 ]; then
  pass "$BENCH launches as shell uid (no LD_LIBRARY_PATH needed)"
  kv bench_launch ok
else
  fail "$BENCH will not launch - is it static? is it +x?"
  kv bench_launch failed
fi
kv bench "$BENCH"
kv bench_sha1 "$(sha1sum "$DEV/$BENCH" 2>/dev/null | cut -d' ' -f1)"
kv model_sha1 "$(sha1sum "$DEV/$MODEL" 2>/dev/null | cut -d' ' -f1)"
[ -f "$DEV/$MODEL" ] && pass "model present" || fail "model missing"

# --------------------------------------------------------- 2. simpleperf

echo "== simpleperf =="
NHW=$(simpleperf stat --print-hw-counter 2>&1 \
      | grep -oE '[0-9]+ CPU PMU hardware counters' | grep -oE '^[0-9]+' | head -1)
kv hw_counters "${NHW:-unknown}"
if [ -n "$NHW" ] && [ "$NHW" -ge 4 ]; then
  pass "$NHW PMU counters (event sets use 4)"
else
  warn "could not determine PMU counter count - watch for multiplexing"
fi

# ------------------------------------------------------------ 3. PINNING

echo "== cpu-mask pinning (GATE) =="
PINREP="$DEV/.pf_pin.txt"
rm -f "$PINREP"
# Warm the page cache first so the measured probe is not dominated by a cold
# 429 MB model load.
( cd "$DEV" && timeout 900 ./"$BENCH" -m "$MODEL" -p 0 -n 8 -r 1 -o json ) \
  >/dev/null 2>&1
# Probe whichever masking mechanism the runner will actually use.
if [ "$MASK_MODE" = "taskset" ]; then
  ( cd "$DEV" && timeout "$PROBE_TIMEOUT" simpleperf stat -e cpu-cycles:u \
      --per-core -o "$PINREP" -- \
      taskset 03 ./"$BENCH" -m "$MODEL" -p 0 -n "$PROBE_N" -t 2 -r 1 \
      -o json ) >/dev/null 2>&1
else
  ( cd "$DEV" && timeout "$PROBE_TIMEOUT" simpleperf stat -e cpu-cycles:u \
      --per-core -o "$PINREP" -- \
      ./"$BENCH" -m "$MODEL" -p 0 -n "$PROBE_N" -t 2 -r 1 \
      -C 0x03 --cpu-strict 1 -o json ) >/dev/null 2>&1
fi
PINRC=$?
kv pin_probe_rc "$PINRC"
kv mask_mode "$MASK_MODE"

if [ ! -s "$PINREP" ]; then
  fail "pinning probe produced no simpleperf report (rc=$PINRC)"
  kv pin_gate no_report
else
  # cpu0-5 are Cortex-A55, cpu6-7 are Cortex-A75. Masked to 0x03 the big
  # cores must be essentially idle.
  #
  # ALL arithmetic stays inside awk. toybox sh does 32-bit signed integer
  # arithmetic, and cycle counts are billions:
  #     $(( 949244217 + 6491805586 )) = -1148884789
  # Summing these in the shell wraps negative, which silently turned this
  # gate into a no-op reporting "counted no cycles at all".
  eval "$(awk '
    $3=="cpu-cycles:u" {
      gsub(/,/,"",$2)
      if ($1+0 <= 5) little += $2; else big += $2
    }
    END {
      tot = little + big
      printf "PIN_LITTLE=%.0f\nPIN_BIG=%.0f\n", little, big
      if (tot > 0) printf "PIN_BIGPCT=%.1f\n", 100*big/tot
      else         printf "PIN_BIGPCT=-1\n"
    }' "$PINREP")"

  kv pin_little_cycles "$PIN_LITTLE"
  kv pin_big_cycles "$PIN_BIG"
  kv pin_big_pct "$PIN_BIGPCT"

  if [ "$PIN_BIGPCT" = "-1" ]; then
    fail "pinning probe counted no cycles (rc=$PINRC) - report truncated?"
    kv pin_gate no_cycles
  elif awk "BEGIN{exit !($PIN_BIGPCT <= $PIN_MAX_BIG_PCT)}"; then
    pass "mask 0x03 honoured: only ${PIN_BIGPCT}% of cycles on A75 (cpu6-7)"
    kv pin_gate ok
  else
    fail "mask 0x03 IGNORED via $MASK_MODE: ${PIN_BIGPCT}% on A75 (cpu6-7)"
    echo "        little (cpu0-5): $PIN_LITTLE cycles"
    echo "        big    (cpu6-7): $PIN_BIG cycles"
    echo "        Masking is not taking effect, so every A55-vs-A75 config"
    echo "        in the matrix measures nothing. If MASK_MODE=cpumask, note"
    echo "        llama-bench -C is ignored on Android before llama.cpp"
    echo "        PR #26838 (2026-08-10) - use MASK_MODE=taskset instead."
    kv pin_gate failed
  fi
fi
rm -f "$PINREP"

# ---------------------------------------------------------- 4. FREQUENCY

echo "== cpufreq telemetry (GATE) =="
FREQLOG="$DEV/.pf_freq.txt"
: > "$FREQLOG"
( cd "$DEV" && timeout 60 ./"$BENCH" -m "$MODEL" -p 0 -n 64 -t 8 -r 1 \
    -o json ) >/dev/null 2>&1 &
LOADPID=$!
_i=0
while [ "$_i" -lt 40 ] && kill -0 "$LOADPID" 2>/dev/null; do
  printf '%s %s\n' \
    "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)" \
    "$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null)" \
    >> "$FREQLOG"
  _i=$((_i + 1)); sleep 0.25
done
wait "$LOADPID" 2>/dev/null

CMAX0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
CMAX6=$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)
kv cpuinfo_max_policy0 "${CMAX0:-unknown}"
kv cpuinfo_max_policy6 "${CMAX6:-unknown}"
P0=$(awk '{print $1}' "$FREQLOG" | sort -u | grep -c .)
P6=$(awk '{print $2}' "$FREQLOG" | sort -u | grep -c .)
P0MAX=$(awk '{if($1+0>m) m=$1+0} END{print m+0}' "$FREQLOG")
P6MAX=$(awk '{if($2+0>m) m=$2+0} END{print m+0}' "$FREQLOG")
kv freq_policy0_distinct "$P0"; kv freq_policy6_distinct "$P6"
kv freq_policy0_max "$P0MAX";   kv freq_policy6_max "$P6MAX"
echo "  policy0: $P0 distinct values, max ${P0MAX}kHz"
echo "  policy6: $P6 distinct values, max ${P6MAX}kHz"
if [ "$P6" -gt 1 ]; then
  pass "policy6 frequency varies - throttle detection can actually fire"
  kv freq_gate ok
else
  # WARNING, not a gate. Unlike the masking fault - where a config measured
  # something other than what it claimed - a clock clamp affects every arm
  # equally, so comparisons between implementations, thread counts and
  # clusters all remain valid. Only ABSOLUTE t/s would be understated. It is
  # also not yet established whether this is a real clamp or simply an
  # unreadable scaling_cur_freq. Blocking a 25 h A/B on an unresolved
  # reporting question would be the wrong trade.
  warn "policy6 reported ONE value under load (${P6MAX}kHz)"
  echo "        Hardware cpuinfo_max_freq is ${CMAX6:-?}kHz, and ${P6MAX}kHz is"
  echo "        the LOWEST entry in scaling_available_frequencies."
  echo "        CONFIRMED BY PMU, not just this sysfs node: a 10 s busy loop"
  echo "        pinned to cpu7 counted 8.39e9 cycles = 0.839 GHz, matching the"
  echo "        reported 0.850 GHz to 1.3%. The big cluster really does sit at"
  echo "        its minimum OPP. Not thermal (status 0), not battery saver,"
  echo "        not uclamp (max=1024), not cpuset - a vendor policy shell uid"
  echo "        cannot see or change. Absolute t/s is ~42% of rated clock;"
  echo "        RELATIVE comparisons are unaffected."
  echo "        Throttle detection is also structurally dead: analyze.py flags"
  echo "        samples below 90% of the observed ceiling, and a constant"
  echo "        series has none, so ignore any 'throttled' column."
  echo "        Relative comparisons stay valid; treat absolute t/s as a"
  echo "        lower bound until this is resolved."
  kv freq_gate warned
fi
rm -f "$FREQLOG"

# ----------------------------------------------------------- 5. wakelock

echo "== suspend prevention =="
WL=$(wakelock_state)
kv wakelock "$WL"
case "$WL" in
  sysfs_writable) pass "wakelock via /sys/power/wake_lock" ;;
  termux_held)    pass "Termux partial wakelock is held - suspend prevented" ;;
  *)              warn "no wakelock detected: suspends can only be DETECTED,
        not prevented. Arms spanning one are invalidated and re-queued.
        Run 'termux-wake-lock' in Termux to prevent them instead." ;;
esac

# ------------------------------------------------------- 6. perfetto path

echo "== perfetto =="
mkdir -p "$TRACE_DIR" "$CFG_DIR" 2>/dev/null
PFCFG="$CFG_DIR/tc_preflight.pbtx"
PFOUT="$TRACE_DIR/preflight.pb"
rm -f "$PFOUT"
printf 'buffers: { size_kb: 4096 }\ndata_sources: { config { name: "linux.sys_stats" sys_stats_config { meminfo_period_ms: 500 } } }\nduration_ms: 700\n' > "$PFCFG"
perfetto -c "$PFCFG" --txt -o "$PFOUT" >/dev/null 2>&1
sleep 1
if [ -s "$PFOUT" ]; then
  pass "perfetto captures from shell uid"
  # the runner must be able to COPY the trace out, not just create it
  if cp "$PFOUT" "$DEV/.pf_copy_test" 2>/dev/null; then
    pass "shell uid can read traces back out of $TRACE_DIR"
    kv perfetto_readable yes
    rm -f "$DEV/.pf_copy_test"
  else
    fail "trace created but shell uid cannot read it back (SELinux)"
    kv perfetto_readable no
  fi
else
  warn "perfetto produced no trace - tracing will be skipped, benchmarks fine"
  kv perfetto_readable no
fi
rm -f "$PFOUT" "$PFCFG"

# ------------------------------------------------------ 7. resources / PC

echo "== resources =="
CAP=$(bat_capacity); ST=$(bat_status); FREE=$(free_mb)
kv battery_capacity "$CAP"; kv battery_status "$ST"; kv free_mb "$FREE"
echo "  battery ${CAP}% $ST, ${FREE}MB free"
case "$ST" in
  *Charging*) warn "battery is CHARGING - energy numbers will be invalid" ;;
  *)          pass "battery discharging" ;;
esac
[ "$CAP" -ge 80 ] && pass "battery >= 80%" \
                  || warn "battery ${CAP}% - a full matrix needs ~80%+"
[ "$FREE" -ge 2000 ] && pass "${FREE}MB free" \
                     || warn "only ${FREE}MB free - traces may be skipped"

AP=$(settings get global airplane_mode_on 2>/dev/null | tr -d '\r')
kv airplane "$AP"
[ "$AP" = "1" ] && pass "airplane mode on" \
                || warn "airplane mode OFF - radio adds power and heat noise"

echo "== PC reachability (informational only) =="
# Deliberately never fatal: surviving an unreachable PC is the entire point.
PCOK=no
for a in ${PC_ADDR:-192.168.0.104}; do
  r=$(send_frame "" "HB preflight" "$a" "${PC_PORT:-9000}" 2 15)
  case "$r" in OK*) PCOK="$a"; break ;; esac
done
kv pc_reachable "$PCOK"
[ "$PCOK" = "no" ] && warn "PC not reachable - arms will queue on device (fine)" \
                   || pass "PC reachable at $PCOK"

# --------------------------------------------------------------- verdict

echo
echo "== summary =="
printf '  pass=%d  warn=%d  fail=%d\n' "$PASS" "$WARN" "$FAIL"
kv pass "$PASS"; kv warn "$WARN"; kv fail "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  kv verdict FAIL
  echo "  -> REFUSING to start a long run. Fix the FAILs above."
  exit 1
fi
kv verdict OK
echo "  -> apparatus validated; safe to start the matrix"
