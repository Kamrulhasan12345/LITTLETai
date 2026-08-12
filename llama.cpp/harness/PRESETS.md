# CPU presets — where the rules come from

`device/cpupreset.sh` picks llama.cpp CPU flags from a phone's own topology.
It changes nothing in llama.cpp; it emits `-t`, `-tb` and a `taskset` prefix
that llama.cpp already understands.

Every constant in it is traceable to an arm in `out/llama-bench/` or
`out/llama-bench-kai/`. This file is that trace. If a rule changes, the
evidence for the change belongs here.

## The problem

`common_cpu_get_num_math()` (`llama.cpp/src/common/common.cpp:205`) is guarded:

```c
#if defined(__x86_64__) && defined(__linux__) && !defined(__ANDROID__)
```

so Android skips the hybrid-CPU heuristic and falls through to
`common_cpu_get_num_physical_cores()` — **8 on this device**. That is the
`tg_t8_free` arm, and it is the worst decode configuration measured:

| | stock | KleidiAI |
|---|---|---|
| default (`-t 8`) | 5.44 t/s | 1.13 t/s |
| `-t 4` | 13.95 t/s | 13.37 t/s |
| **ratio** | **2.6×** | **11.8×** |

Prefill is unaffected — `pp_t8_free` is the fastest prefill arm. The default is
wrong only for decode, which is the half a user waits on.

## Device under measurement

RMX5020 / MT6768, 6× Cortex-A55 (policy0) + 2× Cortex-A75 (policy6), Android 16.
Model Qwen2 1B Q4_0, `poll=50`, masking via `taskset`, seed 1234, 3 batches,
20 reps. Both cpufreq policies were **vendor-clamped to 850 MHz** against rated
1.7 / 2.0 GHz (`preflight.kv`: `freq_policy0_max=850000`,
`freq_policy6_max=850000`). See "Validity limits".

## Criterion 1 — decode does not scale with cores

The Pass B counters arms are the cleanest evidence available, because they run
with `sampler_samples: 0` — no telemetry process competing for a core. Two
independent event-set variants per binary, so four measurements per thread
count:

| threads | stock (a55) | stock (core) | kai (a55) | kai (core) |
|---|---|---|---|---|
| 2 | 11.57 | 11.68 | 11.59 | 11.48 |
| **4** | **14.88** | **14.55** | **13.07** | **13.57** |
| 6 | 15.92 | 12.70 | 11.61 | 11.47 |
| 8 | 13.60 | 9.97 | 6.16 | 5.39 |

t=4 is good in all four columns. t=6 is a coin flip — best in one column, worse
than t=4 in the other three. t=8 is worse in all four and collapses under
KleidiAI.

The sweep arms (which do run the sampler) show the same ordering with a larger
t=8 penalty: 5.44 vs 13.60 stock. **The sampler inflated the magnitude of the
collapse, not its direction** — which is itself a finding, see criterion 5.

→ `T_decode = clamp(floor(C/2), 2, 6)`

## Criterion 2 — the mechanism is barrier spin

Retired instructions per generated token, summed across all CPUs, same arms:

| threads | stock | kai |
|---|---|---|
| 2 | 143 M | 161 M |
| 4 | 185 M | 249 M |
| 6 | 216–302 M | 306–383 M |
| 8 | **365–705 M** | **1053–1231 M** |

Identical work, up to 7.6× the instructions. `ggml_barrier`
(`ggml/src/ggml-cpu/ggml-cpu.c:602`) busy-spins on `ggml_thread_cpu_relax()`
with **no poll gate and no yield**; `--poll` governs only the outer work-wait
loop at `:3188`. With every core occupied and both clusters pinned to the same
850 MHz, the barrier waits on the slowest thread while every other thread burns
cycles.

This is why the rule is a hard cap rather than a preference: the cost is
superlinear in threads, so being wrong upward is much more expensive than being
wrong downward.

## Criterion 3 — prefill and decode want opposite things

> **Partly superseded — see "Prefill sweep".** The direction (prefill wants
> *more* cores than decode) holds, and is why `-t` and `-tb` differ at all. The
> stronger claim below — that prefill wants *all* cores — came from clamped-clock
> data and is **false at full clock**. It was retired after a dedicated sweep;
> `throughput` now emits `C − reserve`, not `C`.

| config | stock t/s | kai t/s | power |
|---|---|---|---|
| pp_t8_free | 47.38 | **48.01** | 1.076 / 0.990 W |
| pp_t6_A55 | 42.21 | 43.65 | 0.931 / **0.871** W |
| pp_t2_A75 | 24.31 | 23.49 | 0.780 / 0.803 W |

Prefill (GEMM, compute-bound) scales to all cores. Decode (GEMV, memory-bound)
peaks at half of them. `-t` and `-tb` already express exactly this split.

→ prefill threads = `C` (throughput), `C - reserve` (balanced), `L` (background)

## Criterion 4 — energy efficiency is not a separate axis

Device-wide tokens/joule, median over 3 batches, stock:

| config | t/s | tokens/J | power |
|---|---|---|---|
| tg_t4_free | 13.95 | **9.22** | 1.489 W |
| tg_t6_free | 13.50 | 8.91 | 1.448 W |
| tg_t2_free | 11.07 | 8.60 | 1.248 W |
| tg_t2_A55 | 5.96 | 6.55 | 0.888 W |
| tg_t8_free | 5.44 | 5.23 | 1.005 W |

That is nearly the throughput ordering. A platform floor of roughly **0.45 W**
(10th percentile of the per-arm minimum power across 49 telemetry files)
dominates the 0.3–1.0 W that compute actually adds, so **race-to-idle wins** and
there is no speed-versus-battery trade to make.

Note `tg_t8_free` draws *less* power (1.005 W) than `tg_t4_free` (1.489 W) while
being 2.6× slower. Spinning threads are cheap per cycle and useless per token —
low power is not efficiency.

The one real exception is prefill on the little cluster: `pp_t6_A55` delivers
**89% of peak throughput at 86% of the power**. That is the entire justification
for `background` existing as a separate preset rather than a marketing name.

## Criterion 5 — thread count carries the benefit; the mask is a refinement

| change | effect |
|---|---|
| `tg_t4_free` 13.95 → `tg_t4_mix` (0xC3) 14.64 | mask worth **+5%** |
| `tg_t8_free` 5.44 → `tg_t4_free` 13.95 | thread count worth **+156%** |

This decides the mechanism. `taskset` is process-wide and therefore cannot give
prefill and decode different masks — but that costs ~5%, while getting the
thread counts right is worth ~156%, and `taskset` is the only mask mechanism
verified to work on this device (see "The `-C` trap").

It is also why `throughput` emits **no mask at all**. Buying decode's +5% with
`taskset c3` would cap prefill at the same 4 cores and lose far more than it
gained.

## Criterion 6 — reserve cores so observation does not perturb

The Pass C control arms measured the harness's own 200 ms sampler against bare
runs, block-paired within a thermal window:

| config | arm | median delta vs bare |
|---|---|---|
| tg_t2_A75 | telemetry | −2.52% |
| tg_t6_free | telemetry | **−8.27%** |
| tg_t2_A75 | simpleperf | −0.68% |
| tg_t6_free | simpleperf | +0.68% |

One background shell loop costs 8% at t=6 and essentially nothing at t=2. The
more cores the model occupies, the more any other runnable thread costs — and on
a phone, "any other thread" means the UI, the launcher, and whatever the user is
doing.

→ `balanced` reserves 2 cores on a machine with ≥6, 1 on 3–5, none below that.

## The rules

Group CPUs by **performance class** — `(cpuinfo_max_freq, MIDR)` — not by
cpufreq policy. Policy count is not cluster count: every x86 pstate driver and
some ARM ones expose one policy per CPU, which would report a 4-core laptop as
four clusters. Order classes by frequency, breaking ties with an
efficiency-core check so a part whose clusters share a ceiling still orders
big-before-little.

Let `C` = online cores, `L` = cores in the slowest class.

| preset | mask | `-t` | `-tb` |
|---|---|---|---|
| `throughput` | none | `T_decode` | `C − reserve` |
| `balanced` | all but `reserve` slowest cores | `T_decode` | `C − reserve` |
| `background` | slowest class only | `min(T_decode, L)` | `L` |

On the measured device:

```
throughput                  -t 4 -tb 6
balanced      taskset cf    -t 4 -tb 6
background    taskset 3f    -t 4 -tb 6
```

`throughput` and `balanced` now differ only in whether the mask is applied.
That is deliberate and it is what the data supports: unpinned is faster on
median but bimodal (threads migrate between clusters, IQR up to 70% of the
median), pinned is slightly slower but never throttled in either sweep. Speed
versus predictability is a real choice; inventing a thread-count difference to
make the presets look more distinct would not be.

`--poll` is deliberately left alone. Nothing in the dataset varies it, and
shipping an untested value would be guessing.

## Validation

`--mode presets --reps 5 --batches 1`, both binaries, `out/presets_stock/` and
`out/presets_kai/`. **Every preset config is now measured directly** — no
interpolated cells remain.

**The clamp was gone for this run.** `freq_policy0_max` came back 1,500,000 kHz
against 850,000 in the original matrices, and policy6 1,532,000. So the 850 MHz
clamp recorded in `HANDOFF.md` was state-dependent, not permanent vendor policy.
Every absolute number below is therefore ~40–70% above the original matrices and
**is not comparable to them**; the comparisons within this section are all
same-run, same-binary.

### Throughput

| config | stock t/s | kai t/s |
|---|---|---|
| pp_balanced (t6, 0xCF) | **90.06** | **89.24** |
| pp_throughput (t8, free) | 80.33 | 82.40 |
| pp_background (t6, 0x3F) | 61.41 | 73.09 |
| tg_balanced (t4, 0xCF) | **20.84** | 13.63 |
| tg_throughput (t4, free) | 19.58 | **18.07** |
| tg_background (t4, 0x3F) | 17.90 | 16.05 |
| **tg_default (t8, free)** | **8.06** | **1.60** |

### Energy

| config | stock J/1k tok | kai J/1k tok |
|---|---|---|
| best preset | **109** | **139** |
| tg_default | 359 | 1462 |
| **ratio** | **3.3×** | **10.5×** |

### What this establishes

1. **The default is wrong, by a lot.** `tg_default` is last in both runs:
   **2.6× slower on stock, 11.3× on KleidiAI**, and **3.3–10.5× more energy per
   token**. This is the claim the work rests on and it is unambiguous.
2. `tg_default` draws *less* power than the presets (2.06 W vs 2.53 W) while
   being 2.6× slower. Spinning is cheap per cycle and useless per token — low
   power is not efficiency.
3. **Prefill does not want all cores.** `pp_balanced` beat `pp_throughput` on
   both binaries (+12.1% stock, +8.3% kai), and `pp_throughput` was thermally
   unstable in both (throttled 1/1 on stock; IQR 22.90 on kai). This supersedes
   the second half of criterion 3.
4. **Differences among the three presets are within noise** at n=5, 1 batch —
   `tg_balanced` is best on stock and worst on kai, with IQR 4.86 and a throttle
   flag. Do not claim a winner among presets from this data. `balanced` is the
   recommended default because it wins prefill on both binaries and never loses
   badly; that is a weaker claim than "fastest" and is the one the data supports.

## Prefill sweep — settling finding 3

Finding 3 said prefill at all cores loses, but `pp_balanced` and `pp_throughput`
differ in thread count **and** mask at once, so nothing attributed the +12%.
`--mode prefill` holds one variable at a time: a thread sweep at a fixed (free)
mask, and a mask sweep at a fixed 6 threads. `--reps 5 --batches 3`, both
binaries, same clamp state (1500000/1532000).

| config | stock t/s | IQR | throttled | kai t/s | IQR | throttled |
|---|---|---|---|---|---|---|
| `pp_t6_free` | **77.70** | 54.32 | 1/3 | 61.61 | 28.53 | 2/3 |
| `pp_t6_bal` (0xCF) | 75.60 | 22.92 | **0/3** | **69.29** | 22.53 | **0/3** |
| `pp_t8_free` | 62.33 | 41.59 | 0/3 | 60.27 | 33.70 | 1/3 |
| `pp_t4_free` | 56.04 | 15.79 | 0/3 | 66.77 | 8.96 | 0/3 |
| `pp_t6_lit` (0x3F) | 55.00 | 8.37 | 3/3 | 56.06 | 20.70 | 3/3 |

**Settled: 6 threads beat 8, every time.** Four independent measurements — two
binaries here, two more in the preset validation — all put t6 above t8. The rule
changed accordingly: `throughput` emits `-tb C − reserve`, and `pp_t6_free` is
now a directly measured arm rather than an interpolation.

**Not settled: whether the mask helps.** Stock puts `t6_free` 2.8% above
`t6_bal`; kai puts it 12.5% below. The binaries disagree, the IQRs swamp the
effect, and 15 back-to-back prefill arms generated enough heat to start
throttling. No mask rule was derived from this, and `throughput` keeps its free
mask.

**Unplanned finding: free masks are bimodal.** Every free-mask config has a huge
IQR (54.32, 41.59, 33.70) while pinned ones are tight (8.37, 22.53), and
`pp_t6_bal` never throttled in either run. That is threads migrating across
clusters — exactly what a large IQR means per `README.md`. It also supplies the
honest distinction between `throughput` and `balanced`: median speed versus
predictability.

**Caveat on this sweep specifically.** It is thermally dirtier than the preset
run: prefill is compute-bound, 15 arms back to back build heat faster than the
decode-heavy preset pass, and the throttle flags show it. The t6-beats-t8
conclusion survives because it holds across four measurements in two separate
sessions; nothing finer should be read out of this table.

## The `-C` trap

llama.cpp's own `-C/--cpu-mask` was **silently ignored on Android** before
PR #26838 (merged 2026-08-10): `ggml-cpu.c` guarded the affinity code with
`#elif defined(__gnu_linux__)`, which Clang does not define for Android target
triples, so the mask reached an unsupported-platform stub. Measured here,
`-C 0x03 --cpu-strict 1` left 99.5% of cycles on the big cores — indistinguishable
from no mask — while `taskset 03` left 0.1%.

A binary older than that fix **accepts the flag and does nothing**, which is the
worst failure mode available: a config that measures something other than what
it claims. `taskset` is a kernel call that cannot be silently dropped, so it is
the default.

The fork at `llama.cpp/src` now **has** the fix
(`ggml/src/ggml-cpu/ggml-cpu.c:2630`, the `#ifdef __ANDROID__`
`sched_setaffinity` path), but the binary currently staged on the device
predates it (`bench_sha1=a69fac33`). Once a binary built from the current fork
is staged, `MASK_MODE=cpumask` becomes usable — and only then does a genuine
prefill/decode mask split become possible, since `-C`/`-Cb` are per-phase where
`taskset` is per-process.

## KleidiAI is a preset input, not a given

MT6768 is ARMv8.2 — dotprod, no i8mm, no SME2. Arm's published KleidiAI wins are
SME2-based. Without it the repacked GEMV path loses on decode while GEMM prefill
still wins:

| | stock | kai | delta |
|---|---|---|---|
| pp_t8_free | 47.38 | 48.01 | +1.3% |
| pp_t6_A55 | 42.21 | 43.65 | +3.4% |
| tg_t4_free | 13.95 | 13.37 | −4.2% |
| tg_t8_free | 5.44 | 1.13 | **−79%** |

So "use the KleidiAI build" is a choice with a prefill/decode trade, not a
free upgrade — and it makes getting `-t` right *more* important, not less.

## Validity limits

- **One SoC.** All rules come from one MT6768. The synthetic topology tests in
  `device/test_cpupreset.sh` check that the *rules* behave sensibly on 4+4,
  1+3+4, 2+2+4, 8×identical and per-CPU-policy layouts, but that is a check of
  the arithmetic, not evidence that the constants are right on those parts.
- **Two clock regimes, and they disagree.** The 97-arm matrices were collected
  at a clamped 850 MHz; the preset validation ran at ~1.5 GHz. The clamp turned
  out to be state-dependent rather than permanent vendor policy. Where the two
  disagree — prefill's core count — **the full-clock data wins**, and the
  clamped conclusion is marked superseded above. Constants live in `t_decode()`
  and `reserve_n()`, so retuning is a one-line change once there is a run to
  justify it.
- **One model** (Qwen2 1B Q4_0). Memory-bound decode behaviour should scale with
  model size, but that is reasoning, not measurement.
- **n=5, 1 batch** in the validation. Enough to establish a 2.6–11.3× gap;
  nowhere near enough to rank the presets against each other.
- **Never compare across runs.** The clamp difference alone moves absolute t/s
  by 40–70%. Every claim here is same-run, same-binary; a preset check must
  baseline the default from the *same* binary in the *same* session.
- **Non-llama output formats are inferred, not measured** — see below.

## Other runtimes — `--format`

`cpupreset.sh` never loads a model and knows nothing about GGUF, ONNX or
TFLite files. It reads `/sys` and prints integers. `--format` selects only how
those integers are **spelled**:

| format | output |
|---|---|
| `llama` (default) | `-t 4 -tb 6` |
| `onnxruntime` | `intra_op_num_threads=4`, `inter_op_num_threads=1` |
| `tflite` | `num_threads=4` |
| `env` | `OMP_NUM_THREADS=4`, `OMP_WAIT_POLICY=passive` |

The `taskset` prefix is identical across all of them, because affinity is a
kernel call rather than a library setting.

**Why it should transfer.** The root cause in criterion 2 is not specific to
ggml. ONNX Runtime's intra-op thread pool and TFLite's XNNPACK/pthreadpool both
spin-wait at barriers, and both default to roughly core count — the same
default, the same pathology. `OMP_WAIT_POLICY=passive` is the direct analogue of
the missing yield in `ggml_barrier`: it makes OpenMP threads sleep at a barrier
instead of spinning.

**Why it is labelled INFERRED.** None of it was measured. Only llama.cpp/ggml
was. `--print` says so on every non-llama format rather than leaving someone to
discover it in their own benchmark.

**One real difference, not just spelling.** A pose estimator or a small
classifier runs one graph per frame — there is no large-batch prefill phase — so
`-tb` has no analogue and these formats emit a single thread count. It is the
conservative one, because the measurements show overshooting is superlinearly
expensive while undershooting is merely linear.

There is deliberately no exec form for these formats: they are library calls,
not argv, and pretending otherwise would produce a command that silently does
nothing.

## Reproducing

```bash
sh device/cpupreset.sh --print balanced     # what this device resolves to, and why
sh device/cpupreset.sh --json               # machine-readable topology + all presets
sh device/cpupreset.sh --format tflite --print balanced
device/test_cpupreset.sh                    # 53 assertions, 18 scenarios, no phone
```

```bash
./deploy.sh --mode presets --reps 5 --batches 1     # ~20 min, 7 arms
```
