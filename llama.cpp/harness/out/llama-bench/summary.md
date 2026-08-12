# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_t8_free | 8 | free | pp | 60 | 43.32 | 14.32 | 10.67 | 51.50 | 0/3 |
| pp_t6_A55 | 6 | 0x3F | pp | 60 | 41.97 | 3.09 | 32.91 | 44.46 | 0/3 |
| pp_t2_A75 | 2 | 0xC0 | pp | 60 | 24.30 | 0.25 | 20.92 | 24.41 | 0/3 |
| tg_t4_mix | 4 | 0xC3 | tg | 60 | 14.60 | 0.74 | 8.70 | 14.99 | 0/3 |
| tg_t4_free | 4 | free | tg | 60 | 14.11 | 0.81 | 10.03 | 14.61 | 0/3 |
| tg_t6_free | 6 | free | tg | 60 | 13.98 | 1.31 | 7.78 | 15.39 | 0/3 |
| tg_t6_A55 | 6 | 0x3F | tg | 60 | 11.99 | 2.27 | 1.45 | 13.31 | 0/3 |
| tg_t2_A75 | 2 | 0xC0 | tg | 60 | 11.42 | 0.15 | 10.46 | 11.57 | 0/3 |
| tg_t2_free | 2 | free | tg | 60 | 11.09 | 0.21 | 10.03 | 11.37 | 0/3 |
| tg_t2_A55 | 2 | 0x03 | tg | 60 | 5.96 | 0.08 | 5.68 | 5.99 | 0/3 |
| tg_t8_free | 8 | free | tg | 60 | 5.49 | 1.51 | 2.36 | 7.01 | 0/3 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_t2_A75 | B0:24.13, B1:24.31, B2:24.36 | 3 |
| pp_t6_A55 | B0:42.21, B1:43.07, B2:41.08 | 3 |
| pp_t8_free | B0:19.47, B1:48.43, B2:47.38 | 3 |
| tg_t2_A55 | B0:5.89, B1:5.98, B2:5.96 | 3 |
| tg_t2_A75 | B0:11.46, B1:11.41, B2:11.43 | 3 |
| tg_t2_free | B0:11.07, B1:11.16, B2:11.07 | 3 |
| tg_t4_free | B0:13.73, B1:14.21, B2:13.95 | 3 |
| tg_t4_mix | B0:14.64, B1:14.15, B2:14.74 | 3 |
| tg_t6_A55 | B0:11.95, B1:8.40, B2:12.03 | 3 |
| tg_t6_free | B0:13.42, B1:14.26, B2:13.50 | 3 |
| tg_t8_free | B0:6.08, B1:5.44, B2:4.86 | 3 |

## PMU derivations

Each row is one simpleperf invocation per (config, event set): `n_invocations = 1`. The PMU values are invocation-level measurements; they are not n=60 independent observations, so no variance is reported for them.

| config | A55 IPC | A75 IPC | A55 ilock% | A55 ldcache% | ilock/ldcache | DRAM GB/s | A75 traffic share | multiplexed |
|---|---|---|---|---|---|---|---|---|
| tg_t2_A55 | 0.544 | 1.169 | 22.4 | 4.7 | 4.75 | - | -% | no |
| tg_t2_A75 | - | 1.012 | - | - | - | - | -% | no |
| tg_t2_free | 0.549 | 1.011 | 22.6 | 5.2 | 4.35 | - | -% | no |
| tg_t4_free | 0.577 | 1.119 | 22.4 | 5.7 | 3.96 | - | -% | no |
| tg_t4_mix | 0.581 | 1.171 | 22.7 | 5.6 | 4.08 | - | -% | no |
| tg_t6_A55 | 0.608 | 1.154 | 20.9 | 12.0 | 1.75 | - | -% | no |
| tg_t6_free | 0.605 | 1.149 | 21.0 | 12.2 | 1.71 | - | -% | no |
| tg_t8_free | 0.691 | 1.322 | 20.5 | 15.3 | 1.34 | - | -% | no |
| tg_t2_A55 | 0.543 | 1.157 | - | - | - | 1.149 | 0.0% | no |
| tg_t2_A75 | - | 1.016 | - | - | - | 6.364 | 100.0% | no |
| tg_t2_free | 0.559 | 1.013 | - | - | - | 6.061 | 99.7% | no |
| tg_t4_free | 0.593 | 1.16 | - | - | - | 5.008 | 79.7% | no |
| tg_t4_mix | 0.576 | 1.073 | - | - | - | 5.562 | 82.0% | no |
| tg_t6_A55 | 0.593 | 1.177 | - | - | - | 2.102 | 0.0% | no |
| tg_t6_free | 0.693 | 1.283 | - | - | - | 3.733 | 67.6% | no |
| tg_t8_free | 0.885 | 1.685 | - | - | - | 2.19 | 57.4% | no |

> `multiplexed = YES` means the kernel time-shared the PMU counters and the counts are scaled estimates. Reduce the event set below the hardware counter count and re-run.

## Harness overhead control

| config | arm | n_blocks | median delta% vs bare | Q1 | Q3 | IQR |
|---|---|---|---|---|---|---|
| tg_t2_A75 | telemetry | 8 | -2.52 | -3.30 | -1.90 | 1.39 | -> above configured tolerance
| tg_t2_A75 | simpleperf | 8 | -0.68 | -1.19 | -0.09 | 1.10 | -> within configured tolerance
| tg_t6_free | telemetry | 8 | -8.27 | -9.33 | -6.33 | 3.00 | -> above configured tolerance
| tg_t6_free | simpleperf | 8 | +0.68 | -1.55 | +2.53 | 4.08 | -> within configured tolerance

> Deltas are block-paired: within a block, the three arms share the same thermal window. The verdict compares the median block-paired delta against a configured engineering tolerance of +/- 1.5% (`CONTROL_NOISE_THRESHOLD_PCT`) - descriptive, not a significance test; a small number of blocks cannot support a p-value claim.

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 1360371s..1372305s), so it includes process setup/teardown; tokens counted per run: `10240`. Scope: `invocation_incl_setup`.
