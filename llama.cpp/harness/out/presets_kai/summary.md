# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_balanced | 6 | 0xCF | pp | 5 | 89.24 | 4.36 | 66.12 | 90.87 | 0/1 |
| pp_throughput | 8 | free | pp | 5 | 82.40 | 22.90 | 53.90 | 89.20 | 0/1 |
| pp_background | 6 | 0x3F | pp | 5 | 73.09 | 8.88 | 67.41 | 77.81 | 1/1 |
| tg_throughput | 4 | free | tg | 5 | 18.07 | 0.34 | 16.55 | 18.25 | 0/1 |
| tg_background | 4 | 0x3F | tg | 5 | 16.05 | 0.38 | 15.69 | 16.14 | 1/1 |
| tg_balanced | 4 | 0xCF | tg | 5 | 13.63 | 4.86 | 12.81 | 18.66 | 1/1 |
| tg_default | 8 | free | tg | 5 | 1.60 | 0.38 | 1.39 | 1.93 | 0/1 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_background | B0:73.09 | 1 |
| pp_balanced | B0:89.24 | 1 |
| pp_throughput | B0:82.40 | 1 |
| tg_background | B0:16.05 | 1 |
| tg_balanced | B0:13.63 | 1 |
| tg_default | B0:1.60 | 1 |
| tg_throughput | B0:18.07 | 1 |

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 9274s..10421s), so it includes process setup/teardown; tokens counted per run: `2560`. Scope: `invocation_incl_setup`.
