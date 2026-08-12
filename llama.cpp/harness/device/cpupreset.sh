#!/system/bin/sh
# cpupreset.sh - pick llama.cpp CPU flags from the device's own topology.
#
# Runs ON the device (or on a laptop against a fake tree via $SYSFS_ROOT).
# POSIX sh for toybox: no bashisms, no arrays, no [[ ]].
#
#   sh cpupreset.sh --print  balanced          # explain what it resolved and why
#   sh cpupreset.sh --flags  balanced          # "-t 4 -tb 6"      (llama.cpp args)
#   sh cpupreset.sh --prefix balanced          # "taskset cf"      (command prefix)
#   sh cpupreset.sh --json                     # detected topology
#   sh cpupreset.sh balanced -- ./llama-cli -m model.gguf -p hi
#
# The last form is the one that is always correct: the prefix has to come
# BEFORE the binary and the flags AFTER it, so a single `$(...)` cannot express
# a preset. --flags/--prefix exist for scripts that already know that.
#
# WHY THIS EXISTS
# ---------------
# llama.cpp's default thread count on Android is common_cpu_get_num_physical_cores(),
# because the hybrid-CPU heuristic next to it is compiled out by
# `#if defined(__x86_64__) && ... && !defined(__ANDROID__)`. On a 6+2 phone that
# default is t=8, which measured 5.4 t/s against 14.0 t/s at t=4 - and 1.1 t/s
# with a KleidiAI build. See PRESETS.md for the arms these rules come from.
#
# MECHANISM: taskset, not --cpu-mask.
# llama.cpp's own -C was silently ignored on Android before PR #26838, so a
# binary older than that accepts the flag and does nothing. taskset is a kernel
# call that cannot be silently dropped, so it is the default. The cost is that
# taskset is process-wide and therefore cannot give prefill and decode
# different masks - measured at ~5%, against the ~156% that the thread counts
# are worth. Set MASK_MODE=cpumask to emit -C/--cpu-strict instead, but only
# with a binary built after PR #26838.

SYSFS_ROOT="${SYSFS_ROOT:-/sys/devices/system/cpu}"
MASK_MODE="${MASK_MODE:-taskset}"
FORMAT="llama"

die() { echo "cpupreset: $*" >&2; exit 1; }

# ------------------------------------------------------------------ helpers

parse_cpulist() {
  # "0-3,6,8-9" -> "0 1 2 3 6 8 9". The kernel uses this form for
  # cpu/online; related_cpus is already space-separated but harmless here.
  echo "$1" | tr ', ' '\n\n' | awk -F- '
    NF==2 && $1!="" { for (i=$1+0; i<=$2+0; i++) printf "%d ", i; next }
    NF==1 && $1!="" { printf "%d ", $1+0 }
  '
}

mask_of() {
  # Space-separated cpu ids -> bare hex mask, built one nibble at a time.
  #
  # Deliberately NOT arithmetic. toybox sh is 32-bit signed and awk's numbers
  # are doubles, so both lose bits on a machine with enough cores; string
  # assembly is exact regardless of core count.
  echo "$1" | awk '
    { for (i = 1; i <= NF; i++) bit[$i + 0] = 1 }
    END {
      hi = -1
      for (c in bit) if (c + 0 > hi) hi = c + 0
      if (hi < 0) { print ""; exit }
      s = ""
      for (n = int(hi / 4); n >= 0; n--) {
        v = 0
        for (b = 3; b >= 0; b--) v = v * 2 + (bit[n * 4 + b] ? 1 : 0)
        s = s sprintf("%x", v)
      }
      print s
    }
  '
}

count_of() { echo "$1" | wc -w | tr -d ' '; }

# first N entries of a space-separated list
take() { echo "$2" | awk -v n="$1" '{ for (i = 1; i <= n && i <= NF; i++) printf "%s ", $i }'; }

# $1 minus the entries in $2
without() {
  echo "$1 | $2" | awk -F'\\|' '
    {
      nd = split($2, drop, " ")
      for (i = 1; i <= nd; i++) if (drop[i] != "") gone[drop[i]] = 1
      na = split($1, all, " ")
      for (i = 1; i <= na; i++)
        if (all[i] != "" && !(all[i] in gone)) printf "%s ", all[i]
    }
  '
}

core_tier() {
  # 0 = efficiency core, 1 = everything else. Used ONLY to break ties when two
  # classes share a frequency ceiling - and when there is no cpufreq at all,
  # where MIDR is the only signal there is. Deliberately not a performance
  # ranking: "is this a little core" is a short, stable, checkable list, while
  # ordering every ARM core by speed is neither.
  echo "$1" | awk '
    {
      m = $0
      if (m == "-" || m == "") { print 1; exit }
      sub(/^0[xX]/, "", m)
      while (length(m) < 8) m = "0" m
      m = tolower(substr(m, length(m) - 7))
      if (substr(m, 1, 2) != "41") { print 1; exit }
      part = substr(m, 5, 3)
      # A35, A53, A55, A510, A520
      little["d04"] = 1; little["d03"] = 1; little["d05"] = 1
      little["d46"] = 1; little["d80"] = 1
      print (part in little) ? 0 : 1
    }
  '
}

core_name() {
  # MIDR_EL1 -> a human label, best effort. Only ever a display string; the
  # rules never branch on it. Values from ARM-software/data cpus.json.
  echo "$1" | awk '
    {
      m = $0
      if (m == "-" || m == "") { print "unknown"; exit }
      sub(/^0[xX]/, "", m)
      while (length(m) < 8) m = "0" m
      m = tolower(substr(m, length(m) - 7))
      imp  = substr(m, 1, 2)
      part = substr(m, 5, 3)
      if (imp != "41") {
        if (imp == "51") { print "Qualcomm"; exit }
        if (imp == "53") { print "Samsung";  exit }
        print "impl-0x" imp; exit
      }
      n["d03"]="Cortex-A53";  n["d04"]="Cortex-A35"; n["d05"]="Cortex-A55"
      n["d07"]="Cortex-A57";  n["d08"]="Cortex-A72"; n["d09"]="Cortex-A73"
      n["d0a"]="Cortex-A75";  n["d0b"]="Cortex-A76"; n["d0d"]="Cortex-A77"
      n["d41"]="Cortex-A78";  n["d44"]="Cortex-X1";  n["d46"]="Cortex-A510"
      n["d47"]="Cortex-A710"; n["d48"]="Cortex-X2";  n["d4d"]="Cortex-A715"
      n["d4e"]="Cortex-X3";   n["d80"]="Cortex-A520"; n["d81"]="Cortex-A720"
      n["d82"]="Cortex-X4"
      print (part in n) ? n[part] : "ARM-0x" part
    }
  '
}

# ---------------------------------------------------------------- topology

cpu_max_khz() {
  # Prefer the per-CPU view; it exists on every layout and needs no parsing.
  _f=$(cat "$SYSFS_ROOT/cpu$1/cpufreq/cpuinfo_max_freq" 2>/dev/null)
  if [ -z "$_f" ]; then
    for p in "$SYSFS_ROOT"/cpufreq/policy*; do
      [ -d "$p" ] || continue
      for c in $(parse_cpulist "$(cat "$p/related_cpus" 2>/dev/null)"); do
        if [ "$c" = "$1" ]; then
          _f=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
          break
        fi
      done
      [ -n "$_f" ] && break
    done
  fi
  case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
  echo "$_f"
}

cpu_midr() {
  _m=$(cat "$SYSFS_ROOT/cpu$1/regs/identification/midr_el1" 2>/dev/null)
  [ -n "$_m" ] || _m="-"
  echo "$_m"
}

# Populates:
#   ONLINE      "0 1 2 ... "   online cpu ids
#   NCPU        count of ONLINE
#   NCLUSTER    number of distinct performance classes
#   CLUSTERS    one record per line: "<max_khz> <midr> <cpu> <cpu> ..."
#               ordered fastest first
#   EVICT       cpus ordered slowest-class-first, descending id within a class -
#               the order in which cores are handed back to the system
detect() {
  ONLINE=$(parse_cpulist "$(cat "$SYSFS_ROOT/online" 2>/dev/null)")
  if [ -z "$ONLINE" ]; then
    # No cpu/online (some emulators, and any fake tree that omits it):
    # fall back to whatever cpuN directories exist.
    ONLINE=$(for d in "$SYSFS_ROOT"/cpu[0-9]*; do
               [ -d "$d" ] && basename "$d" | sed 's/^cpu//'
             done | sort -n | tr '\n' ' ')
  fi
  [ -n "$ONLINE" ] || die "no online CPUs found under $SYSFS_ROOT"
  NCPU=$(count_of "$ONLINE")

  # Group by PERFORMANCE CLASS - (max frequency, MIDR) - not by cpufreq policy.
  #
  # Policy count is not cluster count. Plenty of kernels expose one policy per
  # CPU (every x86 pstate driver does, and some ARM ones), which would report a
  # 4-core laptop as four clusters and make "the slowest cluster" a single
  # core. Frequency alone would in turn merge a 4+4 part whose two clusters
  # share a ceiling but not a microarchitecture, so MIDR joins the key.
  _rows=""
  for c in $ONLINE; do
    _midr=$(cpu_midr "$c")
    _rows="$_rows$(cpu_max_khz "$c") $(core_tier "$_midr") $_midr $c
"
  done

  # Sort on frequency first, then on tier so that two classes sharing a ceiling
  # still order big-before-little. Without the tier a 4+4 part whose clusters
  # cap at the same GHz would fall back to sysfs order, which puts cpu0 - a
  # little core on every ARM SoC - at the top and inverts every preset.
  CLUSTERS=$(echo "$_rows" | grep -v '^ *$' | awk '
    {
      key = $1 SUBSEP $3
      if (!(key in seen)) {
        seen[key] = 1; order[++n] = key
        khz[key] = $1; tier[key] = $2; midr[key] = $3
      }
      cpus[key] = cpus[key] " " $4
    }
    END {
      for (i = 1; i <= n; i++) { k = order[i]; print khz[k] " " tier[k] " " midr[k] cpus[k] }
    }
  ' | sort -k1,1nr -k2,2nr -s)
  NCLUSTER=$(echo "$CLUSTERS" | grep -c .)

  # Eviction order: slowest class first, highest cpu id first within it.
  # Highest-id-first keeps cpu0 in every mask - it is where a lot of kernel and
  # IRQ work lands, so it is the last core worth taking away.
  EVICT=$(echo "$CLUSTERS" | sed -n '1!G;h;$p' | awk '
    { for (i = NF; i >= 4; i--) printf "%s ", $i }
  ')
}

cluster_cpus()  { echo "$1" | cut -d' ' -f4-; }
cluster_khz()   { echo "$1" | cut -d' ' -f1; }
cluster_midr()  { echo "$1" | cut -d' ' -f3; }
slowest_cluster_cpus() { cluster_cpus "$(echo "$CLUSTERS" | tail -n 1)"; }

# ------------------------------------------------------------------- rules
#
# Every constant here is traceable to a measured arm; see PRESETS.md.
#
#   T_decode  decode peaked at 4 of 8 cores in all four independent
#             sampler-free measurements, and degraded monotonically past it as
#             barrier spin cost grew (143M -> 705M instructions per token).
#   prefill   scales with total cores: pp_t8_free 47.4 t/s > pp_t6_A55 42.2.
#   reserve   cores kept back so the UI - and any sampler - does not land on a
#             spinning worker. The control pass measured the harness's own
#             200ms sampler costing -8.3% at t=6 for exactly this reason.

t_decode() {
  # clamp(floor(NCPU/2), 2, 6)
  _t=$((NCPU / 2))
  [ "$_t" -lt 2 ] && _t=2
  [ "$_t" -gt 6 ] && _t=6
  [ "$_t" -gt "$NCPU" ] && _t=$NCPU
  echo "$_t"
}

reserve_n() {
  # How many cores balanced hands back. Scaled so a small machine is not
  # crippled: giving up 2 of 4 cores would cost more than the responsiveness
  # is worth, while on 8 it is the difference the control pass measured.
  if   [ "$NCPU" -ge 6 ]; then echo 2
  elif [ "$NCPU" -ge 3 ]; then echo 1
  else echo 0
  fi
}

resolve() {
  # Sets PRE_MASK (bare hex or ""), P_T (decode threads), P_TB (prefill threads).
  _preset="$1"
  _td=$(t_decode)

  case "$_preset" in
    throughput)
      # No mask at all. tg_t4_mix (0xC3) beat tg_t4_free by 5%, but taskset is
      # process-wide, so buying that 5% for decode would cap prefill at the
      # same 4 cores and cost far more than it gained. Leaving the mask off
      # also lets 6 threads float across all 8 cores, which measured faster on
      # median than pinning - at the cost of being bimodal (IQR up to 70% of
      # the median as threads migrate between clusters). That trade is the
      # difference between this preset and `balanced`.
      PRE_MASK=""
      P_T=$_td
      # NOT $NCPU. Prefill loses at all-cores in every measurement taken:
      # t6 beat t8 on both binaries in the prefill sweep (77.70/75.60 vs 62.33
      # stock, 69.29/61.61 vs 60.27 kai) and again in the preset validation
      # (90.06 vs 80.33, 89.24 vs 82.40). The earlier "prefill scales to all
      # cores" rule came from clamped-clock data and did not survive contact
      # with a real clock.
      P_TB=$((NCPU - $(reserve_n)))
      [ "$P_TB" -lt 1 ] && P_TB=1
      ;;
    balanced)
      _drop=$(take "$(reserve_n)" "$EVICT")
      _keep=$(without "$ONLINE" "$_drop")
      [ -n "$_keep" ] || _keep="$ONLINE"
      PRE_MASK=$(mask_of "$_keep")
      _n=$(count_of "$_keep")
      P_T=$_td
      [ "$P_T" -gt "$_n" ] && P_T=$_n
      P_TB=$_n
      ;;
    background)
      # The slowest class only: pp_t6_A55 delivered 89% of peak prefill at 86%
      # of the power, and leaves the fast cores entirely to the system. On a
      # single-class machine there is no slow cluster to retreat to, so take
      # half the cores instead.
      if [ "$NCLUSTER" -gt 1 ]; then
        _cpus=$(slowest_cluster_cpus)
      else
        _half=$((NCPU / 2)); [ "$_half" -lt 1 ] && _half=1
        _cpus=$(take "$_half" "$EVICT")
      fi
      _n=$(count_of "$_cpus")
      PRE_MASK=$(mask_of "$_cpus")
      P_T=$_td
      [ "$P_T" -gt "$_n" ] && P_T=$_n
      P_TB=$_n
      ;;
    *)
      die "unknown preset '$_preset' (throughput|balanced|background)"
      ;;
  esac
  [ "$P_T"  -lt 1 ] && P_T=1
  [ "$P_TB" -lt 1 ] && P_TB=1
  return 0
}

# --------------------------------------------------------------- rendering

prefix_str() {
  # taskset wants a bare hex mask, same as runner.sh's mask_prefix().
  [ -n "$PRE_MASK" ] || return 0
  [ "$MASK_MODE" = "taskset" ] || return 0
  printf 'taskset %s' "$PRE_MASK"
}

generic_threads() {
  # One thread count for runtimes that have no prefill/decode split.
  #
  # A pose estimator or a small ONNX classifier runs ONE graph per frame -
  # there is no large-batch prefill phase to scale up for - so -tb has no
  # analogue and the conservative number is the only defensible one. We know
  # from the llama.cpp measurements that overshooting is superlinearly
  # expensive while undershooting is merely linear, so when in doubt, fewer.
  _g=$P_T
  [ -n "$PRE_MASK" ] && _g=$(count_of "$(mask_cpus)")
  [ "$_g" -gt "$P_T" ] && _g=$P_T
  [ "$_g" -lt 1 ] && _g=1
  echo "$_g"
}

mask_cpus() {
  # The cpus currently selected by PRE_MASK, as a list.
  [ -n "$PRE_MASK" ] || { echo "$ONLINE"; return; }
  echo "$ONLINE" | awk -v m="$PRE_MASK" '
    BEGIN {
      n = length(m)
      for (i = 0; i < n; i++) {
        c = tolower(substr(m, n - i, 1))
        v = index("0123456789abcdef", c) - 1
        for (b = 0; b < 4; b++) if (int(v / (2 ^ b)) % 2) on[i * 4 + b] = 1
      }
    }
    { for (i = 1; i <= NF; i++) if ($i in on) printf "%s ", $i }
  '
}

flags_str() {
  # $1 = 1 to omit -tb (llama-bench has no such flag)
  #
  # Only the SPELLING is engine-specific. The numbers below come from the same
  # topology rules whatever the format, and the taskset prefix is unchanged
  # because affinity is a kernel call, not a library setting.
  case "$FORMAT" in
    llama)
      printf -- '-t %s' "$P_T"
      [ "${1:-0}" = "1" ] || printf -- ' -tb %s' "$P_TB"
      if [ -n "$PRE_MASK" ] && [ "$MASK_MODE" = "cpumask" ]; then
        printf -- ' -C 0x%s --cpu-strict 1' "$PRE_MASK"
      fi
      ;;
    onnxruntime)
      # SessionOptions. inter_op stays 1: these are single-stream latency
      # workloads, and parallel subgraph execution only adds contention.
      printf 'intra_op_num_threads=%s\ninter_op_num_threads=1' "$(generic_threads)"
      ;;
    tflite)
      printf 'num_threads=%s' "$(generic_threads)"
      ;;
    env)
      # OMP_WAIT_POLICY is the direct analogue of the root cause: it tells
      # OpenMP threads to sleep at a barrier instead of spinning, which is
      # exactly what ggml_barrier does not do.
      printf 'OMP_NUM_THREADS=%s\nOMP_WAIT_POLICY=passive' "$(generic_threads)"
      ;;
    *)
      die "unknown format '$FORMAT' (llama|onnxruntime|tflite|env)"
      ;;
  esac
}

format_note() {
  # Printed by --print only. These rules were measured on llama.cpp/ggml and
  # nowhere else; saying so in the tool is cheaper than someone discovering it
  # in a benchmark later.
  [ "$FORMAT" = "llama" ] && return 0
  echo
  echo "note:     thread count is INFERRED for $FORMAT, not measured."
  echo "          ONNX Runtime's intra-op pool and TFLite's XNNPACK/pthreadpool"
  echo "          spin-wait at barriers like ggml_barrier does, and both default"
  echo "          to roughly core count, so the same oversubscription penalty"
  echo "          applies - but only llama.cpp/ggml was measured here."
  echo "          Single-graph runtimes have no prefill/decode split, so there"
  echo "          is no -tb analogue and this is the conservative count."
}

wants_no_tb() {
  # llama-bench takes -t but not -tb, and exits with usage on an unknown flag.
  # Dropping it silently beats a confusing failure at the end of a deploy.
  case "$(basename "$1")" in llama-bench*) return 0 ;; *) return 1 ;; esac
}

emit_json() {
  printf '{\n  "ncpu": %s,\n  "nclusters": %s,\n  "clusters": [\n' "$NCPU" "$NCLUSTER"
  echo "$CLUSTERS" | (
    _first=1
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      _cpus=$(cluster_cpus "$rec")
      [ "$_first" = 1 ] || printf ',\n'
      _first=0
      printf '    {"max_khz": %s, "core": "%s", "ncpu": %s, "cpus": "%s", "mask": "0x%s"}' \
        "$(cluster_khz "$rec")" "$(core_name "$(cluster_midr "$rec")")" \
        "$(count_of "$_cpus")" "$(echo "$_cpus" | sed 's/  */ /g;s/^ //;s/ *$//')" \
        "$(mask_of "$_cpus")"
    done
  )
  printf '\n  ],\n  "presets": {\n'
  _sep=""
  for p in throughput balanced background; do
    resolve "$p"
    printf '%s    "%s": {"threads": %s, "threads_batch": %s, "mask": "%s"}' \
      "$_sep" "$p" "$P_T" "$P_TB" \
      "$([ -n "$PRE_MASK" ] && echo "0x$PRE_MASK" || echo free)"
    _sep=",
"
  done
  printf '\n  }\n}\n'
}

emit_print() {
  resolve "$1"
  echo "topology: $NCPU online CPUs in $NCLUSTER performance class(es)"
  echo "$CLUSTERS" | while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _cpus=$(cluster_cpus "$rec")
    printf '  cpus %-14s %-12s max %s kHz  mask 0x%s\n' \
      "$(echo "$_cpus" | sed 's/  */ /g;s/^ //;s/ *$//')" \
      "$(core_name "$(cluster_midr "$rec")")" \
      "$(cluster_khz "$rec")" "$(mask_of "$_cpus")"
  done
  echo
  echo "preset:   $1"
  if [ "$FORMAT" = "llama" ]; then
    echo "decode:   -t $P_T"
    echo "prefill:  -tb $P_TB"
  else
    echo "threads:  $(generic_threads)"
  fi
  echo "mask:     $([ -n "$PRE_MASK" ] && echo "0x$PRE_MASK ($MASK_MODE)" || echo "free")"
  echo
  if [ "$FORMAT" = "llama" ]; then
    _pfx=$(prefix_str)
    echo "usage:    ${_pfx:+$_pfx }./llama-cli -m model.gguf $(flags_str) -p 'hi'"
  else
    echo "settings ($FORMAT):"
    flags_str | sed 's/^/  /'
    _pfx=$(prefix_str)
    if [ -n "$_pfx" ]; then
      echo
      echo "affinity: $_pfx <your program>"
      echo "          (a kernel call, so it works whatever the engine)"
    fi
  fi
  format_note
}

# -------------------------------------------------------------------- main

while [ $# -ge 2 ] && [ "$1" = "--format" ]; do
  FORMAT="$2"; shift 2
done

[ $# -ge 1 ] || die "usage: cpupreset.sh [--format F] [--print|--flags|--prefix] <preset>
       cpupreset.sh --json
       cpupreset.sh <preset> -- <cmd...>
       F = llama (default) | onnxruntime | tflite | env"

detect

case "$1" in
  --json)   emit_json; exit 0 ;;
  --print)  [ $# -ge 2 ] || die "--print needs a preset"; emit_print "$2"; exit 0 ;;
  --flags)  [ $# -ge 2 ] || die "--flags needs a preset"; resolve "$2"
            flags_str "${NO_TB:-0}"; echo; exit 0 ;;
  --prefix) [ $# -ge 2 ] || die "--prefix needs a preset"; resolve "$2"
            prefix_str; echo; exit 0 ;;
  -*)       die "unknown option '$1'" ;;
esac

[ "$FORMAT" = "llama" ] || die "--format $FORMAT has no exec form: the settings \
are library calls, not argv. Use --flags or --print and apply them in your code."

PRESET="$1"; shift
[ "${1:-}" = "--" ] || die "expected -- before the command to run"
shift
[ $# -ge 1 ] || die "nothing to run after --"

resolve "$PRESET"

_notb=0
wants_no_tb "$1" && _notb=1

# The ordering that makes the exec form worth having: prefix, binary, flags.
_pfx=$(prefix_str)
# shellcheck disable=SC2086
exec $_pfx "$@" $(flags_str "$_notb")
