# LITTLETai — llama.cpp is 2.6–11× slower than it needs to be on your phone

**One flag fixes it.** `llama.cpp`'s default thread count on Android is *all
physical cores*, which on a big.LITTLE SoC is the single worst configuration
available. This repo proves that with PMU counters, explains the mechanism, and
ships a tool that picks the right flags from any Arm phone's own CPU topology.

Measured on a retail mid-range handset (realme RMX5020, MediaTek Helio G85),
Qwen2 1B Q4_0, token generation:

| | stock llama.cpp | with KleidiAI |
|---|---|---|
| **default** (`-t 8`) | 8.06 t/s · 359 J/1k tok | 1.60 t/s · 1462 J/1k tok |
| **any LITTLETai preset** | 19.6–20.8 t/s · 109–140 J/1k tok | 13.6–18.1 t/s · 134–192 J/1k tok |
| **speedup** | **2.4–2.6×** | **8.5–11.3×** |
| **energy per token** | **2.6–3.3× less** | **7.6–11× less** |

No model changes. No recompilation. No root. The model, the binary and the
prompt are identical — only the CPU flags differ.

```bash
# before
./llama-cli -m model.gguf -p "hello"

# after
sh cpupreset.sh balanced -- ./llama-cli -m model.gguf -p "hello"
```

---

## Why this happens

`common_cpu_get_num_math()` in llama.cpp picks the default thread count. It has
a hybrid-CPU heuristic — for Intel P/E cores. It is guarded like this:

```c
#if defined(__x86_64__) && defined(__linux__) && !defined(__ANDROID__)
```

So on Android it falls through to "all physical cores" = 8. Arm's big.LITTLE is
the most widely deployed heterogeneous CPU architecture on earth, and it is
explicitly excluded from the one heuristic that exists for heterogeneous CPUs.

The cost is measurable, not theoretical. Retired instructions **per generated
token**, summed across all cores, from `simpleperf` PMU counters:

| threads | stock | KleidiAI |
|---|---|---|
| 2 | 143 M | 161 M |
| 4 | 185 M | 249 M |
| 6 | 216–302 M | 306–383 M |
| **8 (the default)** | **365–705 M** | **1053–1231 M** |

Identical work, up to **7.6× the instructions**. `ggml_barrier()` busy-spins on
`ggml_thread_cpu_relax()` with no yield and no poll gate. Put a thread on every
core of a heterogeneous SoC and the barrier waits on the slowest one while all
the others burn cycles. The default *guarantees* zero spare cores, so it hits
the worst case every time.

This also explains why the KleidiAI build collapses harder: this SoC is
ARMv8.2-A with `asimddp` but **no `i8mm`, no SVE, no SME2** (verified in
`/proc/cpuinfo`), so KleidiAI's repacked GEMV path falls back to a slower kernel
for decode — which makes the spin-wait window longer, which makes
oversubscription hurt more. Prefill, which is GEMM-bound, still wins with
KleidiAI.

## What LITTLETai does

`cpupreset.sh` reads the device's CPU topology from `/sys` and emits the flags
llama.cpp already understands. **It does not patch llama.cpp** and it never
loads a model.

- Groups CPUs by **performance class** — `(max frequency, MIDR)` — not by
  cpufreq policy, because plenty of kernels expose one policy per CPU
- Decodes MIDR to core names (Cortex-A55, A710, X2 …) with an efficiency-core
  tie-breaker, so a part whose clusters share a frequency ceiling still orders
  correctly
- Applies rules derived from 238 measured benchmark arms
- Emits `-t` / `-tb` plus a `taskset` prefix, or settings for other runtimes

Three presets, by intent:

| preset | for | on a 6+2 phone |
|---|---|---|
| `throughput` | fastest median, tolerates jitter | `-t 4 -tb 6` |
| `balanced` *(default)* | never throttled in any run; leaves cores for the UI | `taskset cf -t 4 -tb 6` |
| `background` | lowest power and heat; big cores stay free | `taskset 3f -t 4 -tb 6` |

## Target platform

Everything here targets **Arm AArch64 Android, unrooted, shell uid**.

| | |
|---|---|
| CPU | 6× **Arm Cortex-A55** @ 1.7 GHz + 2× **Arm Cortex-A75** @ 2.0 GHz, DynamIQ big.LITTLE |
| ISA | ARMv8.2-A, NEON, `asimddp` (dotprod), `fphp`/`asimdhp`; no `i8mm`, no SVE, no SME2 |
| SoC | MediaTek Helio G85 (`ro.board.platform=mt6768`, `ro.soc.model=MT6769`) |
| Device | realme RMX5020, Android 16, kernel 6.6.118, 5.6 GB RAM |
| Access | no root, no Shizuku; `/data/local/tmp` as shell uid |

The **rules generalise by construction** — they are a function of cluster count,
core counts and frequency ceilings, not of this SoC. `device/test_cpupreset.sh`
checks them against 12 synthetic topologies (4+4, 1+3+4, 2+2+4, 8×identical,
per-CPU-policy layouts, offline CPUs, no-cpufreq) with no phone attached. The
*constants* come from one device; the *arithmetic* is tested broadly.

## Quick start

```bash
git clone https://github.com/Kamrulhasan12345/littletai
cd littletai/llama.cpp/harness/device

sh cpupreset.sh --print balanced        # explain what this machine resolves to
sh cpupreset.sh --json                  # machine-readable topology + all presets
./test_cpupreset.sh                     # 53 assertions, no device needed
```

`cpupreset.sh` is POSIX sh for toybox — it runs on an Android phone with no
Python, no busybox and no coreutils beyond what ships in the ROM.

Use it as a launcher (correct by construction — the `taskset` prefix must come
*before* the binary and the flags *after* it):

```bash
sh cpupreset.sh balanced -- ./llama-cli -m model.gguf -p "hello"
```

Or ask for the pieces:

```bash
sh cpupreset.sh --flags  balanced   # -t 4 -tb 6
sh cpupreset.sh --prefix balanced   # taskset cf
```

### Other runtimes

Only the *spelling* is engine-specific; the topology rules are the same, and the
`taskset` prefix is identical because affinity is a kernel call.

```bash
sh cpupreset.sh --format onnxruntime --flags balanced   # intra_op_num_threads=4
sh cpupreset.sh --format tflite      --flags balanced   # num_threads=4
sh cpupreset.sh --format env         --flags balanced   # OMP_NUM_THREADS=4 ...
```

ONNX Runtime's intra-op pool and TFLite's XNNPACK/pthreadpool spin-wait at
barriers the same way and default to roughly core count, so the same
oversubscription penalty should apply. **Only llama.cpp/ggml was measured** —
the tool prints `INFERRED` on those formats rather than implying otherwise.

## How the numbers were produced

The measurements are the point, so the apparatus is part of the deliverable.
`llama.cpp/harness/` is a device-side benchmark harness built for this project:

- **The phone runs the benchmark loop.** The laptop generates a seeded plan,
  receives results over TCP, and analyses them. `adb` copies files once and
  starts the runner detached, then is free to die.
- **Randomised, interleaved, block-structured** so thermal drift cannot align
  with a single config.
- **Thermal gating** — every arm waits for a temperature floor before measuring.
- **Named failure states.** An arm ends as a measurement or as a reason
  (`thermal_gate_timeout`, `bench_json_missing`, `suspend_during_measurement` …),
  never as a plausible-looking number.
- **Energy** from the fuel gauge at 200 ms, trapezoidally integrated, screen off
  and unplugged.
- **PMU counters** via `simpleperf --per-core`, with multiplexing detection.
- **Harness overhead measured, not assumed** — a control pass showed the
  sampler itself costs −8.3% at 6 threads, which is *why* `balanced` reserves
  cores.

238 benchmark arms across five passes. Plans are seeded and reproducible: the two
97-arm matrices in `llama.cpp/harness/out/` regenerate byte-identically.

### Results in this repo

| directory | what |
|---|---|
| `out/presets_stock/`, `out/presets_kai/` | **the headline A/B** — presets vs the llama.cpp default |
| `out/prefill_stock/`, `out/prefill_kai/` | prefill thread/mask sweep |
| `out/llama-bench/`, `out/llama-bench-kai/` | the 97-arm matrices, stock vs KleidiAI |

Each contains `summary.md`, `results.csv`, per-arm telemetry, and figures
(`fig_throughput.png`, `fig_energy.png`, `fig_timeline.png`).

**[`llama.cpp/harness/PRESETS.md`](llama.cpp/harness/PRESETS.md) traces every
rule constant back to the arm it came from** — including a rule the validation
run contradicted, and what was changed as a result.

## Reproducing

You need an unrooted Android phone, `adb`, and about 40 minutes.
[`llama.cpp/harness/RUNBOOK.md`](llama.cpp/harness/RUNBOOK.md) is the full
session, including the two physical prerequisites that silently ruin a run.

```bash
cd llama.cpp/harness
./deploy.sh --prep
./deploy.sh --mode presets --reps 5 --batches 1 --out out/presets_stock
.venv/bin/python ingest.py  out/presets_stock --watch
.venv/bin/python analyze.py out/presets_stock
```

Expected: `tg_default` (8 threads) last in the throughput table, roughly 2.6×
below the presets on stock and 11× below on KleidiAI.

## Tests

209 assertions, none of which need a phone:

```bash
cd llama.cpp/harness
device/test_cpupreset.sh                      # 53  topology + preset rules
python3 -m unittest discover -p 'test_*.py'   # 107 result model, plan, ingest
device/test_runner.sh                         # 35  device loop vs a fake tree
./e2e_dryrun.sh                               # 14  whole pipeline, no device
```

## Limitations

Stated plainly, because the rules are only as good as what produced them.

- **Constants come from one SoC.** The arithmetic is tested against 12 synthetic
  topologies; the numbers are not.
- **One model** (Qwen2 1B Q4_0). Decode is memory-bound so behaviour should
  scale with model size — that is reasoning, not measurement.
- **Two clock regimes.** Early runs hit a vendor clamp at 850 MHz; later ones ran
  at ~1.5 GHz. Absolute t/s differs 40–70% between them, so every comparison in
  this repo is same-run and same-binary. Where the two disagreed, the full-clock
  data won and the superseded claim is marked as such.
- **The mask question is unresolved.** Whether pinning helps prefill is not
  settled — the two binaries disagreed and the noise swamped the effect. No mask
  rule was derived from it.
- **Non-llama output formats are inferred**, not measured.

## Layout

```
llama.cpp/harness/
  device/cpupreset.sh        the tool - topology -> flags (POSIX sh)
  device/test_cpupreset.sh   53 assertions, 12 synthetic topologies
  PRESETS.md                 every rule traced to the arm it came from
  RUNBOOK.md                 how to run a measurement session
  README.md                  harness architecture and design rationale
  SETUP_LOG.md               the bring-up log, including what broke
  out/                       results, summaries and figures
```

`llama.cpp/harness/` is **self-contained** — reading or running `cpupreset.sh`
and its tests needs nothing from the `llama.cpp/src` submodule, which is only
required to build benchmark binaries.

## License

MIT — see [`LICENSE`](LICENSE). Vendored llama.cpp is separately MIT, Copyright
(c) 2023-2026 The ggml authors.
