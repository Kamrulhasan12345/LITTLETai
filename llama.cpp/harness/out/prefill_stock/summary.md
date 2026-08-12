# Benchmark summary

## Throughput (median, IQR)

| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |
|---|---|---|---|---|---|---|---|---|---|
| pp_t6_free | 6 | free | pp | 15 | 77.70 | 54.32 | 29.14 | 91.22 | 1/3 |
| pp_t6_bal | 6 | 0xCF | pp | 15 | 75.60 | 22.92 | 62.07 | 91.33 | 0/3 |
| pp_t8_free | 8 | free | pp | 15 | 62.33 | 41.59 | 25.97 | 90.18 | 0/3 |
| pp_t4_free | 4 | free | pp | 15 | 56.04 | 15.79 | 46.07 | 67.80 | 0/3 |
| pp_t6_lit | 6 | 0x3F | pp | 15 | 55.00 | 8.37 | 48.57 | 77.77 | 3/3 |

> IQR, not stddev. A large IQR means the distribution is bimodal (threads migrating across clusters) and the median is the only honest summary.

> Samples are per-repetition from llama-bench `samples_ts`, nested inside `rep_batch` batches. Older results only have the aggregate `avg_ts`; for them `n` = JSON rows, not reps.

### Per-batch medians (t/s)
| config | per-batch medians | batches |
|---|---|---|
| pp_t4_free | B0:47.51, B1:66.76, B2:56.04 | 3 |
| pp_t6_bal | B0:63.92, B1:90.35, B2:84.83 | 3 |
| pp_t6_free | B0:33.52, B1:89.21, B2:90.04 | 3 |
| pp_t6_lit | B0:67.49, B1:51.93, B2:53.98 | 3 |
| pp_t8_free | B0:27.70, B1:62.33, B2:87.12 | 3 |

## Energy

Device-wide tokens/joule (screen off, unplugged). Treat as +/-15-25%: whole-device draw, ~1s fuel-gauge granularity, no CPU rail isolation.

> `tokens_per_joule` here is derived from `energy_j_timestamped` (see `extra.energy_metric_used` in each result).

> Energy window is the benchmark *invocation* window on the device clock (boottime 14211s..16445s), so it includes process setup/teardown; tokens counted per run: `2560`. Scope: `invocation_incl_setup`.
