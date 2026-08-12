# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_t8_free | 8 | free | pp | 60 | 47.89 | 2.74 | 21.32 | 50.41 | 0/3 |
| pp_t6_A55 | 6 | 0x3F | pp | 60 | 43.45 | 2.51 | 33.85 | 45.84 | 0/3 |
| pp_t2_A75 | 2 | 0xC0 | pp | 60 | 23.45 | 0.87 | 10.31 | 23.60 | 0/3 |
| tg_t4_free | 4 | free | tg | 60 | 13.44 | 0.35 | 12.50 | 13.92 | 0/3 |
| tg_t4_mix | 4 | 0xC3 | tg | 60 | 13.37 | 0.62 | 8.83 | 14.29 | 0/3 |
| tg_t2_A75 | 2 | 0xC0 | tg | 60 | 11.29 | 0.63 | 5.50 | 11.44 | 0/3 |
| tg_t2_free | 2 | free | tg | 60 | 11.09 | 0.18 | 2.58 | 11.24 | 0/3 |
| tg_t6_free | 6 | free | tg | 60 | 10.68 | 1.14 | 3.15 | 11.94 | 0/3 |
| tg_t6_A55 | 6 | 0x3F | tg | 60 | 9.56 | 0.99 | 4.34 | 10.37 | 0/3 |
| tg_t2_A55 | 2 | 0x03 | tg | 60 | 6.77 | 0.06 | 6.16 | 6.89 | 0/3 |
| tg_t8_free | 8 | free | tg | 60 | 1.13 | 0.15 | 0.34 | 1.30 | 0/3 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_t2_A75 | B0:23.49, B1:20.60, B2:23.51 | 3 |
| pp_t6_A55 | B0:42.53, B1:45.41, B2:43.65 | 3 |
| pp_t8_free | B0:48.01, B1:48.82, B2:46.11 | 3 |
| tg_t2_A55 | B0:6.80, B1:6.75, B2:6.80 | 3 |
| tg_t2_A75 | B0:8.96, B1:11.33, B2:11.30 | 3 |
| tg_t2_free | B0:10.93, B1:11.08, B2:11.15 | 3 |
| tg_t4_free | B0:13.31, B1:13.54, B2:13.37 | 3 |
| tg_t4_mix | B0:13.18, B1:13.73, B2:13.19 | 3 |
| tg_t6_A55 | B0:10.23, B1:9.05, B2:9.42 | 3 |
| tg_t6_free | B0:10.58, B1:10.35, B2:10.78 | 3 |
| tg_t8_free | B0:1.11, B1:1.13, B2:1.13 | 3 |

## PMU derivations

Each row is one simpleperf invocation per (config, event set): `n_invocations = 1`. The PMU values are invocation-level measurements; they are not n=60 independent observations, so no variance is reported for them.

| config | A55 IPC | A75 IPC | A55 ilock% | A55 ldcache% | ilock/ldcache | DRAM GB/s | A75 traffic share | multiplexed |
|---|---|---|---|---|---|---|---|---|
| tg_t2_A55 | 0.689 | 1.18 | 13.3 | 6.3 | 2.11 | - | -% | no |
| tg_t2_A75 | - | 1.125 | - | - | - | - | -% | no |
| tg_t2_free | 0.677 | 1.126 | 12.2 | 8.2 | 1.49 | - | -% | no |
| tg_t4_free | 0.7 | 1.346 | 12.9 | 12.5 | 1.04 | - | -% | no |
| tg_t4_mix | 0.696 | 1.347 | 12.4 | 12.2 | 1.02 | - | -% | no |
| tg_t6_A55 | 0.729 | 1.17 | 14.4 | 18.7 | 0.77 | - | -% | no |
| tg_t6_free | 0.751 | 1.487 | 14.4 | 17.9 | 0.8 | - | -% | no |
| tg_t8_free | 0.96 | 1.868 | 19.0 | 12.8 | 1.48 | - | -% | no |
| tg_t2_A55 | 0.693 | 1.152 | - | - | - | 1.374 | 0.0% | no |
| tg_t2_A75 | - | 1.125 | - | - | - | 5.115 | 100.0% | no |
| tg_t2_free | 0.668 | 1.12 | - | - | - | 5.504 | 99.8% | no |
| tg_t4_free | 0.686 | 1.321 | - | - | - | 4.383 | 77.9% | no |
| tg_t4_mix | 0.705 | 1.337 | - | - | - | 4.405 | 84.7% | no |
| tg_t6_A55 | 0.724 | 1.168 | - | - | - | 1.591 | 0.0% | no |
| tg_t6_free | 0.755 | 1.479 | - | - | - | 3.184 | 66.9% | no |
| tg_t8_free | 0.994 | 1.928 | - | - | - | 1.47 | 58.5% | no |

> `multiplexed = YES` means the kernel time-shared the PMU counters and the counts are scaled estimates. Reduce the event set below the hardware counter count and re-run.

## Harness overhead control

| config | arm | n_blocks | median delta% vs bare | Q1 | Q3 | IQR |
|---|---|---|---|---|---|---|
| tg_t2_A75 | telemetry | 8 | -1.83 | -2.07 | -1.22 | 0.85 | -> above configured tolerance
| tg_t2_A75 | simpleperf | 8 | -0.02 | -0.40 | +0.32 | 0.73 | -> within configured tolerance
| tg_t6_free | telemetry | 8 | -8.08 | -9.12 | -6.04 | 3.08 | -> above configured tolerance
| tg_t6_free | simpleperf | 8 | -1.66 | -3.28 | -0.46 | 2.81 | -> above configured tolerance

> Deltas are block-paired: within a block, the three arms share the same thermal window. The verdict compares the median block-paired delta against a configured engineering tolerance of +/- 1.5% (`CONTROL_NOISE_THRESHOLD_PCT`) - descriptive, not a significance test; a small number of blocks cannot support a p-value claim.

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 1398666s..1437094s), so it includes process setup/teardown; tokens counted per run: `10240`. Scope: `invocation_incl_setup`.
