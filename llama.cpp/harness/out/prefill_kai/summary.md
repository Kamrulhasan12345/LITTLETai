# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_t6_bal | 6 | 0xCF | pp | 15 | 69.29 | 22.53 | 62.69 | 91.29 | 0/3 |
| pp_t4_free | 4 | free | pp | 15 | 66.77 | 8.96 | 45.37 | 68.54 | 0/3 |
| pp_t6_free | 6 | free | pp | 15 | 61.61 | 28.53 | 25.72 | 101.92 | 2/3 |
| pp_t8_free | 8 | free | pp | 15 | 60.27 | 33.70 | 38.09 | 87.03 | 1/3 |
| pp_t6_lit | 6 | 0x3F | pp | 15 | 56.06 | 20.70 | 45.39 | 76.40 | 3/3 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_t4_free | B0:68.06, B1:62.25, B2:66.77 | 3 |
| pp_t6_bal | B0:89.43, B1:65.78, B2:67.66 | 3 |
| pp_t6_free | B0:41.22, B1:89.11, B2:60.30 | 3 |
| pp_t6_lit | B0:75.99, B1:56.06, B2:52.26 | 3 |
| pp_t8_free | B0:82.45, B1:60.27, B2:42.10 | 3 |

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 16934s..19904s), so it includes process setup/teardown; tokens counted per run: `2560`. Scope: `invocation_incl_setup`.
