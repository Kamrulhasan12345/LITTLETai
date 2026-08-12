#!/usr/bin/env bash
# test_cpupreset.sh - topology tests for cpupreset.sh, run on the LAPTOP.
#
#   ./test_cpupreset.sh          # all scenarios
#   ./test_cpupreset.sh 1+3+4    # only scenarios whose name matches
#
# cpupreset.sh reads everything through $SYSFS_ROOT, so a fake sysfs tree is
# enough to test it against a dozen devices we do not own. That is the whole
# point: the rules have to be right on the phones nobody here has, and a
# synthetic tree is the only way to check that before shipping.
#
# The tests assert on RESOLVED FLAGS - what a user would actually get - not on
# intermediate topology state.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"
PASS=0; FAIL=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

should_run() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------------ harness

# MIDRs, so a cluster split that shares a frequency ceiling still resolves.
MIDR_A55=0x00000000410fd050
MIDR_A75=0x00000000410fd0a0
MIDR_A78=0x00000000410fd410
MIDR_X1=0x00000000410fd440

# mk_tree <spec>...   where each spec is "<ncpu>:<max_khz>:<midr>"
# Builds a fake /sys/devices/system/cpu with per-CPU cpufreq (the layout every
# modern kernel exposes) and one policy directory per distinct group.
mk_tree() {
  ROOT=$(mktemp -d /tmp/cpupreset_test.XXXXXX)
  cpu=0
  pol=0
  for spec in "$@"; do
    n=${spec%%:*};   rest=${spec#*:}
    khz=${rest%%:*}; midr=${rest#*:}
    rel=""
    for _ in $(seq 1 "$n"); do
      mkdir -p "$ROOT/cpu$cpu/cpufreq" "$ROOT/cpu$cpu/regs/identification"
      echo "$khz"  > "$ROOT/cpu$cpu/cpufreq/cpuinfo_max_freq"
      echo "$midr" > "$ROOT/cpu$cpu/regs/identification/midr_el1"
      rel="$rel$cpu "
      cpu=$((cpu+1))
    done
    mkdir -p "$ROOT/cpufreq/policy$pol"
    echo "$khz" > "$ROOT/cpufreq/policy$pol/cpuinfo_max_freq"
    echo "$rel" > "$ROOT/cpufreq/policy$pol/related_cpus"
    pol=$cpu
  done
  echo "0-$((cpu-1))" > "$ROOT/online"
  export SYSFS_ROOT="$ROOT"
}

rm_tree() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; unset SYSFS_ROOT; }

# expect <preset> <want-prefix> <want-flags>
expect() {
  gotp=$(sh "$HERE/cpupreset.sh" --prefix "$1" 2>&1)
  gotf=$(sh "$HERE/cpupreset.sh" --flags  "$1" 2>&1)
  if [ "$gotp" = "$2" ] && [ "$gotf" = "$3" ]; then
    ok "$SCEN/$1 -> ${2:-(no prefix)} $3"
  else
    bad "$SCEN/$1"
    printf '       want: %-18s %s\n' "${2:-(none)}" "$3"
    printf '       got:  %-18s %s\n' "${gotp:-(none)}" "$gotf"
  fi
}

# ---------------------------------------------------------------- scenarios

# The device the rules were measured on. These three lines are the regression
# oracle: if they change, the presets no longer match PRESETS.md.
t_6plus2_rmx5020() {
  SCEN="6+2 (MT6768, the measured device)"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset cf" "-t 4 -tb 6"
  expect background "taskset 3f" "-t 4 -tb 6"
  rm_tree
}

t_1plus3plus4() {
  SCEN="1+3+4 (prime/big/little flagship)"
  hdr "$SCEN"
  mk_tree "4:1800000:$MIDR_A55" "3:2600000:$MIDR_A78" "1:3000000:$MIDR_X1"
  # Slowest class is the 4 littles (cpu0-3) -> background masks to 0xf.
  # balanced gives back the two highest littles, cpu3 and cpu2 -> 0xf3.
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset f3" "-t 4 -tb 6"
  expect background "taskset f"  "-t 4 -tb 4"
  rm_tree
}

t_2plus2plus4() {
  SCEN="2+2+4"
  hdr "$SCEN"
  mk_tree "4:1800000:$MIDR_A55" "2:2400000:$MIDR_A78" "2:2800000:$MIDR_X1"
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset f3" "-t 4 -tb 6"
  expect background "taskset f"  "-t 4 -tb 4"
  rm_tree
}

t_4plus4_same_freq() {
  SCEN="4+4 same ceiling, different microarch"
  hdr "$SCEN"
  # The case frequency alone cannot separate: both clusters cap at 2.0 GHz.
  # Only the MIDR in the grouping key keeps them apart.
  mk_tree "4:2000000:$MIDR_A55" "4:2000000:$MIDR_A75"
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset f3" "-t 4 -tb 6"
  expect background "taskset f"  "-t 4 -tb 4"
  rm_tree
}

t_8_identical() {
  SCEN="8x identical (no slow cluster to retreat to)"
  hdr "$SCEN"
  mk_tree "8:2000000:$MIDR_A55"
  # One performance class, so background takes half the cores rather than
  # collapsing onto the whole machine.
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset 3f" "-t 4 -tb 6"
  expect background "taskset f0" "-t 4 -tb 4"
  rm_tree
}

t_4_core_budget() {
  SCEN="4x identical (small machine, reserve must not cripple it)"
  hdr "$SCEN"
  mk_tree "4:1800000:$MIDR_A55"
  expect throughput ""          "-t 2 -tb 3"
  expect balanced   "taskset 7" "-t 2 -tb 3"
  expect background "taskset c" "-t 2 -tb 2"
  rm_tree
}

t_dual_core() {
  SCEN="2x identical (degenerate, must not emit -t 0)"
  hdr "$SCEN"
  mk_tree "2:1400000:$MIDR_A55"
  expect throughput ""          "-t 2 -tb 2"
  expect balanced   "taskset 3" "-t 2 -tb 2"
  expect background "taskset 2" "-t 1 -tb 1"
  rm_tree
}

t_12_core() {
  SCEN="4+8 wide (decode clamp must hold at 6)"
  hdr "$SCEN"
  mk_tree "8:2000000:$MIDR_A55" "4:2800000:$MIDR_X1"
  # floor(12/2)=6, and the clamp keeps it there rather than climbing.
  expect throughput ""            "-t 6 -tb 10"
  expect balanced   "taskset f3f" "-t 6 -tb 10"
  expect background "taskset ff"  "-t 6 -tb 8"
  rm_tree
}

t_offline_cpus() {
  SCEN="offline CPUs are excluded"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"
  echo "0-3,6-7" > "$ROOT/online"      # cpu4 and cpu5 hot-unplugged
  # 6 online cores: 4 littles + 2 bigs.
  expect throughput ""           "-t 3 -tb 4"
  expect balanced   "taskset c3" "-t 3 -tb 4"
  expect background "taskset f"  "-t 3 -tb 4"
  rm_tree
}

t_no_cpufreq() {
  SCEN="no cpufreq at all (emulator / locked kernel)"
  hdr "$SCEN"
  ROOT=$(mktemp -d /tmp/cpupreset_test.XXXXXX)
  for c in 0 1 2 3; do mkdir -p "$ROOT/cpu$c"; done
  echo "0-3" > "$ROOT/online"
  export SYSFS_ROOT="$ROOT"
  # Degrades to one undifferentiated class rather than failing.
  expect throughput ""          "-t 2 -tb 3"
  expect balanced   "taskset 7" "-t 2 -tb 3"
  expect background "taskset c" "-t 2 -tb 2"
  rm_tree
}

t_policy_only_layout() {
  SCEN="policy-only layout (no per-CPU cpufreq symlink)"
  hdr "$SCEN"
  ROOT=$(mktemp -d /tmp/cpupreset_test.XXXXXX)
  for c in 0 1 2 3 4 5 6 7; do
    mkdir -p "$ROOT/cpu$c/regs/identification"
    if [ "$c" -lt 6 ]; then echo "$MIDR_A55" > "$ROOT/cpu$c/regs/identification/midr_el1"
    else                    echo "$MIDR_A75" > "$ROOT/cpu$c/regs/identification/midr_el1"; fi
  done
  mkdir -p "$ROOT/cpufreq/policy0" "$ROOT/cpufreq/policy6"
  echo 1700000     > "$ROOT/cpufreq/policy0/cpuinfo_max_freq"
  echo "0 1 2 3 4 5" > "$ROOT/cpufreq/policy0/related_cpus"
  echo 2000000     > "$ROOT/cpufreq/policy6/cpuinfo_max_freq"
  echo "6 7"       > "$ROOT/cpufreq/policy6/related_cpus"
  echo "0-7"       > "$ROOT/online"
  export SYSFS_ROOT="$ROOT"
  # Must reach the same answer as the per-CPU layout in t_6plus2.
  expect throughput ""           "-t 4 -tb 6"
  expect balanced   "taskset cf" "-t 4 -tb 6"
  expect background "taskset 3f" "-t 4 -tb 6"
  rm_tree
}

t_per_cpu_policies() {
  SCEN="one cpufreq policy per CPU (x86 pstate layout)"
  hdr "$SCEN"
  # Policy count is not cluster count. Grouping on policies would call this
  # four clusters and hand background a single core.
  ROOT=$(mktemp -d /tmp/cpupreset_test.XXXXXX)
  for c in 0 1 2 3; do
    mkdir -p "$ROOT/cpu$c/cpufreq" "$ROOT/cpufreq/policy$c"
    echo 3500000 > "$ROOT/cpu$c/cpufreq/cpuinfo_max_freq"
    echo 3500000 > "$ROOT/cpufreq/policy$c/cpuinfo_max_freq"
    echo "$c"    > "$ROOT/cpufreq/policy$c/related_cpus"
  done
  echo "0-3" > "$ROOT/online"
  export SYSFS_ROOT="$ROOT"
  nc=$(sh "$HERE/cpupreset.sh" --json | grep '"nclusters"' | tr -dc '0-9')
  if [ "$nc" = "1" ]; then ok "$SCEN/collapses to 1 performance class"
  else bad "$SCEN/nclusters want 1, got $nc"; fi
  expect background "taskset c" "-t 2 -tb 2"
  rm_tree
}

t_llama_bench_drops_tb() {
  SCEN="llama-bench gets no -tb"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"

  # Real stubs, not `echo`: the flag is chosen from argv[0], so a wrapper would
  # test the wrapper's name instead of the binary's and always pass.
  BIN=$(mktemp -d /tmp/cpupreset_bin.XXXXXX)
  for b in llama-bench llama-cli; do
    printf '#!/bin/sh\necho "%s $*"\n' "$b" > "$BIN/$b"
    chmod +x "$BIN/$b"
  done

  got=$(sh "$HERE/cpupreset.sh" balanced -- "$BIN/llama-bench" -m model.gguf)
  want="llama-bench -m model.gguf -t 4"
  if [ "$got" = "$want" ]; then ok "$SCEN"
  else bad "$SCEN"; printf '       want: %s\n       got:  %s\n' "$want" "$got"; fi

  got=$(sh "$HERE/cpupreset.sh" balanced -- "$BIN/llama-cli" -m model.gguf)
  want="llama-cli -m model.gguf -t 4 -tb 6"
  if [ "$got" = "$want" ]; then ok "$SCEN/llama-cli keeps -tb"
  else bad "$SCEN/llama-cli"; printf '       want: %s\n       got:  %s\n' "$want" "$got"; fi

  # The prefix must actually be applied, and applied BEFORE the binary.
  # Asserting on real affinity is not portable - the kernel intersects the mask
  # with the CPUs that exist, so `taskset cf` becomes `f` on a 4-core host and
  # the test would fail for a reason that has nothing to do with the rules.
  # Intercepting taskset checks the thing that matters instead.
  printf '#!/bin/sh\nm=$1; shift; echo "mask=$m cmd=$(basename "$1")"\n' > "$BIN/taskset"
  chmod +x "$BIN/taskset"
  got=$(PATH="$BIN:$PATH" sh "$HERE/cpupreset.sh" balanced -- "$BIN/llama-cli" -m model.gguf)
  if [ "$got" = "mask=cf cmd=llama-cli" ]; then ok "$SCEN/taskset prefix applied before the binary"
  else bad "$SCEN/prefix want 'mask=cf cmd=llama-cli', got '${got:-empty}'"; fi

  rm -rf "$BIN"
  rm_tree
}

t_cpumask_mode() {
  SCEN="MASK_MODE=cpumask emits -C instead of taskset"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"
  gotp=$(MASK_MODE=cpumask sh "$HERE/cpupreset.sh" --prefix balanced)
  gotf=$(MASK_MODE=cpumask sh "$HERE/cpupreset.sh" --flags  balanced)
  if [ -z "$gotp" ] && [ "$gotf" = "-t 4 -tb 6 -C 0xcf --cpu-strict 1" ]; then
    ok "$SCEN"
  else
    bad "$SCEN"; printf '       got: prefix=%s flags=%s\n' "${gotp:-(none)}" "$gotf"
  fi
  rm_tree
}

t_bad_preset() {
  SCEN="unknown preset fails loudly"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"
  if sh "$HERE/cpupreset.sh" --flags turbo >/dev/null 2>&1; then
    bad "$SCEN/should have exited nonzero"
  else
    ok "$SCEN"
  fi
  rm_tree
}

t_output_formats() {
  SCEN="output formats spell the same numbers differently"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"

  # The point of --format: only the SPELLING is engine-specific. A single-graph
  # runtime has no prefill phase, so it gets one conservative thread count.
  check() {
    # Multi-line output joined with ';' for a one-line comparison; the final
    # newline would otherwise show up as a trailing separator.
    got=$(sh "$HERE/cpupreset.sh" --format "$1" --flags "$2" | tr '\n' ';' | sed 's/;$//')
    if [ "$got" = "$3" ]; then ok "$SCEN/$1 $2"
    else bad "$SCEN/$1 $2"; printf '       want: %s\n       got:  %s\n' "$3" "$got"; fi
  }
  check llama       balanced "-t 4 -tb 6"
  check onnxruntime balanced "intra_op_num_threads=4;inter_op_num_threads=1"
  check tflite      balanced "num_threads=4"
  check env         balanced "OMP_NUM_THREADS=4;OMP_WAIT_POLICY=passive"
  # background masks to the 6 A55s, so the generic count is still the clamp, 4.
  check tflite      background "num_threads=4"
  # throughput has no mask at all, so nothing narrows the clamp either.
  check tflite      throughput "num_threads=4"

  # Affinity is a kernel call, so the prefix must not depend on the format.
  a=$(sh "$HERE/cpupreset.sh" --prefix balanced)
  b=$(sh "$HERE/cpupreset.sh" --format onnxruntime --prefix balanced)
  if [ "$a" = "$b" ] && [ "$a" = "taskset cf" ]; then
    ok "$SCEN/prefix is format-independent"
  else bad "$SCEN/prefix '$a' vs '$b'"; fi

  # An unmeasured format must say so rather than implying it was validated.
  if sh "$HERE/cpupreset.sh" --format tflite --print balanced | grep -q INFERRED; then
    ok "$SCEN/inferred formats are labelled"
  else bad "$SCEN/tflite --print does not say INFERRED"; fi
  if sh "$HERE/cpupreset.sh" --print balanced | grep -q INFERRED; then
    bad "$SCEN/llama should NOT be labelled inferred"
  else ok "$SCEN/llama is not labelled inferred"; fi

  if sh "$HERE/cpupreset.sh" --format pytorch --flags balanced >/dev/null 2>&1; then
    bad "$SCEN/unknown format should exit nonzero"
  else ok "$SCEN/unknown format fails loudly"; fi

  # There is no exec form for library settings - refusing beats pretending.
  if sh "$HERE/cpupreset.sh" --format tflite balanced -- /bin/true >/dev/null 2>&1; then
    bad "$SCEN/exec with a non-llama format should be refused"
  else ok "$SCEN/exec refused for library-setting formats"; fi

  rm_tree
}

t_generic_threads_narrow_machine() {
  SCEN="generic thread count respects a narrow mask"
  hdr "$SCEN"
  # 2 little + 2 big: background masks to 2 cores, so the generic count must
  # follow the mask down rather than emitting a clamp the mask cannot satisfy.
  mk_tree "2:1500000:$MIDR_A55" "2:2200000:$MIDR_A78"
  got=$(sh "$HERE/cpupreset.sh" --format tflite --flags background)
  if [ "$got" = "num_threads=2" ]; then ok "$SCEN"
  else bad "$SCEN want num_threads=2, got '$got'"; fi
  rm_tree
}

t_core_names() {
  SCEN="MIDR decodes to core names"
  hdr "$SCEN"
  mk_tree "6:1700000:$MIDR_A55" "2:2000000:$MIDR_A75"
  j=$(sh "$HERE/cpupreset.sh" --json)
  if echo "$j" | grep -q 'Cortex-A75' && echo "$j" | grep -q 'Cortex-A55'; then
    ok "$SCEN"
  else
    bad "$SCEN"; echo "$j" | sed 's/^/       /'
  fi
  rm_tree
}

# -------------------------------------------------------------------- main

for t in t_6plus2_rmx5020 t_1plus3plus4 t_2plus2plus4 t_4plus4_same_freq \
         t_8_identical t_4_core_budget t_dual_core t_12_core t_offline_cpus \
         t_no_cpufreq t_policy_only_layout t_per_cpu_policies \
         t_llama_bench_drops_tb t_cpumask_mode t_bad_preset \
         t_output_formats t_generic_threads_narrow_machine t_core_names; do
  should_run "$t" && "$t"
done

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
