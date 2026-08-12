# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_balanced | 6 | 0xCF | pp | 5 | 90.06 | 2.28 | 72.23 | 90.97 | 0/1 |
| pp_throughput | 8 | free | pp | 5 | 80.33 | 5.03 | 58.25 | 85.66 | 1/1 |
| pp_background | 6 | 0x3F | pp | 5 | 61.41 | 10.47 | 50.91 | 70.55 | 1/1 |
| tg_balanced | 4 | 0xCF | tg | 5 | 20.84 | 0.17 | 20.58 | 20.97 | 0/1 |
| tg_throughput | 4 | free | tg | 5 | 19.58 | 1.73 | 17.05 | 19.91 | 0/1 |
| tg_background | 4 | 0x3F | tg | 5 | 17.90 | 0.02 | 17.38 | 17.94 | 1/1 |
| tg_default | 8 | free | tg | 5 | 8.06 | 3.74 | 2.76 | 9.91 | 0/1 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_background | B0:61.41 | 1 |
| pp_balanced | B0:90.06 | 1 |
| pp_throughput | B0:80.33 | 1 |
| tg_background | B0:17.90 | 1 |
| tg_balanced | B0:20.84 | 1 |
| tg_default | B0:8.06 | 1 |
| tg_throughput | B0:19.58 | 1 |

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 8255s..8958s), so it includes process setup/teardown; tokens counted per run: `2560`. Scope: `invocation_incl_setup`.
