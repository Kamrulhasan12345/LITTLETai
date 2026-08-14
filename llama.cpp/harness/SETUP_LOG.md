# lbench bring-up log — Helio G81 Ultra (mt6768, Android 16)

Chronological record of getting the harness from a fresh checkout to a
completed, validated control run on the device, including every crash, its
root cause, and the exact fix. Copy-paste workflows at the end.
Recorded 2026-08-07→10 (through §14).

## 0. Starting state

- Device: MediaTek Helio G81 Ultra, SoC `mt6768` (6× Cortex-A55 @1.7 GHz + 2× Cortex-A75
  @2.0 GHz), Android 16 (SDK 36), kernel `6.6.118-android15-...`
- `llama-bench` (17.5 MB), `model.gguf` (491 MB, qwen2 1B Q4_K),
  `libssl.so.3`/`libcrypto.so.3` already staged in `/data/local/tmp`
- adb connected over USB, battery charging, airplane mode off

## 1. Readiness check

```bash
./probe.sh
```

Result: **18 PASS / 0 FAIL / 3 WARN** (governor unreadable = expected without
root; battery charging; airplane off). One discrepancy vs README: **7 PMU
hardware counters**, not 6 — event budget is 7.

## 2. Hygiene (order matters)

```bash
adb tcpip 5555 && adb connect 192.168.0.102:5555   # phone IP on wlan0
# then pull the USB cable
adb shell settings put global airplane_mode_on 1   # WiFi stays up for adb
adb shell input keyevent KEYCODE_SLEEP             # screen off
```

Verify: battery `status` = `Discharging`, airplane = `1`, `wlan0` still has
its IP, `mWakefulness=Asleep`. Reconnecting later **resets airplane mode to 0**
and wakes the screen — re-apply hygiene after any reconnect.

## 3. Fuel-gauge validation (energy_check.sh saga)

### 3a. Problem: energy_check.sh hangs past its duration

`./energy_check.sh 300` laptop-side loops with **one adb call per second**
(two per sample: current + voltage). Over wireless adb each call is ~1-2 s,
so 300 samples take >10 min. Its logic is fine; the loop is the bottleneck
on wireless.

### 3b. Solution: sample on-device instead

```bash
# /tmp/opencode/energy_probe.sh -> /data/local/tmp/energy_probe.sh
adb push /tmp/opencode/energy_probe.sh /data/local/tmp/
adb shell 'rm -f /data/local/tmp/energy_probe.log; \
  sh /data/local/tmp/energy_probe.sh </dev/null >/dev/null 2>&1 &'
# poll the log every ~12 s until 300 samples; then
adb pull /data/local/tmp/energy_probe.log /tmp/opencode/energy_probe.log
```

Script: reads `charge_counter` (C0), starts `llama-bench -n 512 -r 100 -t 6`
under load, samples `current_now`/`voltage_now` every 1 s for 240–300 s,
kills the bench, reads C1. `LD_LIBRARY_PATH=/data/local/tmp` is required
inside the script or the bench never launches (see 6b).

### 3c. Lessons learned mid-probe

1. **Bookend C0/C1 to the same window.** First attempt reused a
   `charge_counter` value from an aborted run → delta covered a longer window
   → 2.6× mismatch. Always read C0 at probe start.
2. **Verify the load actually runs.** First probe omitted `LD_LIBRARY_PATH`,
   so `llama-bench` failed to launch and we measured idle (flat ~130 mA).
   Fixed by exporting `LD_LIBRARY_PATH=$DEV` and logging `load_running=yes`
   after a 5 s `kill -0 $BENCH_PID`.
3. **Units, not sign:** `current_now` reads positive under idle/load and
   negative when charging.

### 3d. Result (validated on-device run)

| metric | value |
|---|---|
| C0 → C1 | 3396000 → 3375000 uAh (21 mAh over 240 s) |
| mean \|current_now\| | 323 (raw) |
| integrated as mA | 21556 uAh → ratio vs coulomb **1.026** ✓ |
| mean voltage_now | 4043 raw = **4.04 V** |

**Verdict: `current_now` is in mA, `voltage_now` is in mV.**

### 3e. Config change

```python
ENERGY_I_SCALE = 1e-3      # was 1e-6 (uA assumption)
ENERGY_V_SCALE = 1e-3      # was 1e-6 (uV assumption)
```

## 4. Pass A/B crashes fixed before the control run

### 4a. Crash #1: missing files

```python
python3 harness.py --mode control
# FileNotFoundError: .../harness/harness/trace_config.pbtx
```

README's layout implies a `harness/` subdir for `trace_config.pbtx` +
`sampler.sh`, but they were at repo root. Fix:

```bash
mkdir -p harness && mv trace_config.pbtx sampler.sh harness/
```

### 4b. Crash #2: "thermal zones tracked: 0 of 0"

Probe counted 37 zones but they're SELinux-gated on this MTK kernel: **every**
`/sys/class/thermal/thermal_zone*/type` and `*/temp` is denied to shell uid.
`temp_mC()` fallback added in `harness.py` — when sysfs zones are empty it
parses the ThermalHAL:

```python
def temp_mC():
    # 1) try sysfs zones
    # 2) fallback: dumpsys thermalservice, split on
    #    "Current temperatures from HAL", regex SOC|CPU|GPU|SKIN,
    #    mValue in 0.1 degC -> * 1000 to milli-degC
```

Gotchas:
- Split on `Current temperatures from HAL` — the "Cached temperatures" block
  above it holds stale values (64.5 °C) that would poison the max.
- mValue is 0.1 °C: `36.7` → 36700 mC (**×1000**, not ×100 — caught when the
  gate reported 3.7 °C).

### 4c. Crash #3: adb shell hangs on backgrounded sampler

```
TimeoutExpired ... 'cd /data/local/tmp && nohup sh sampler.sh 200 ... &'
```

Isolation experiments (`timeout 8 adb shell '<cmd>'`):

| pattern | result |
|---|---|
| `cd X && sh s.sh &` | **hang** (rc=124) — `&` backgrounds the whole list, keeps a copy of the adb pipe |
| `sh s.sh ... </dev/null >/dev/null 2>&1 &` | returns immediately (rc=0) |
| `nohup sh s.sh ... </dev/null >/dev/null 2>&1 &` | returns immediately (rc=0) |

Fix in `Telemetry.start`:

```python
sh(f"nohup sh {DEV}/sampler.sh {SAMPLE_MS} {self.dev_csv} "
   f"{DEV}/zones.txt </dev/null >/dev/null 2>&1 &")
```

Rule: **never use `cd X && ... &` in an adb shell string; absolute paths +
`nohup` + all three fds redirected.**

### 4d. Crash #4: Perfetto captures nothing

Perfetto can't read configs from `/data/local/tmp` — the sanctioned location
is `/data/misc/perfetto-configs` (readable by perfetto's uid):

```python
sh(f"mkdir -p /data/misc/perfetto-configs")
cfg_dev = f"/data/misc/perfetto-configs/tc_{self.tag}.pbtx"
```

Verified: `perfetto -c ... --background-wait --txt -o ...` → rc=0, trace
created (~971 B short, ~1.6 MB bench window). Last line of `--background-wait`
output is the daemon pid; `re.search(r"(\d+)")` picks it up, `kill -TERM`
stops it.

## 5. Bug found by review: Pass B counters silently empty

In `run_counters` the whole command's stdout was redirected, so simpleperf's
report (written to stdout) landed inside `devjson`:

```python
simpleperf stat -e ... --per-core -- ./llama-bench ... -o json > {devjson}
```

Fix — simpleperf's own `-o` separates report from JSON:

```python
simpleperf stat -e ... --per-core -o {devrep} -- ./llama-bench ... -o json > {devjson}
counters, multiplexed = parse_simpleperf(sh(f"cat {devrep}"))
```

## 6. Pre-flight verification

- `avg_ts` is the right JSON field (`llama-bench -o json` confirmed; each -r
  20 test emits **one** object whose `avg_ts` already averages the reps)
- On-device sampler produces a valid CSV (freq policies + battery columns)
- Smoke run `--mode control --reps 2 --control-n 1` completes all 3 arms +
  verdict in ~4.5 min, pulls telemetry CSV + Perfetto trace
- `analyze.py out/run_X` writes `summary.md`
- matplotlib missing → venv (system python is externally managed):

```bash
python3 -m venv /tmp/opencode/benchvenv
/tmp/opencode/benchvenv/bin/pip install matplotlib
# run everything through /tmp/opencode/benchvenv/bin/python
```

## 6b. PMU event audit (all `-e` names verified live)

Counter budget and every event name were checked on the device before
relying on them (2026-08-07, no scripts edited):

```bash
adb shell 'simpleperf stat --print-hw-counter'     # -> 7 counters on every cpu
# smoke test each event set (note: exit 124 from `timeout` is expected -
# simpleperf's workload wrapper returns it, not an error)
adb shell 'simpleperf stat -e <events> --duration 2 -- timeout 2 sleep 3'
# --per-core mode (what the harness uses):
adb shell 'simpleperf stat -e <events> --per-core --duration 2 -- timeout 2 sleep 3'
```

| event | counts? | role |
|---|---|---|
| `cpu-cycles:u` | ✅ | cycles retired |
| `instructions:u` | ✅ | work retired |
| `raw-stall-backend:u` | ✅ | execution-pipe stall cycles |
| `raw-ll-cache-miss-rd:u` | ✅ | last-level read miss → DRAM read |
| `raw-cortex-a55-stall-backend-ilock:u` | ✅ | A55 in-order dependency (interlock) |
| `raw-cortex-a55-stall-backend-ld-cache:u` | ✅ | A55 load-to-use dependency |

All 6 verified counting, and `--per-core` emits one row block per cpu that
`parse_simpleperf` matches exactly. Confirmed again on a real llama-bench
load (counts > 0 per cpu; note the load was post-deep-sleep, so slow).

Caveats to carry into the writeup:

1. **`ilock` counts even on idle `sleep`** — the raw event name is whatever
   this kernel registers; the *meaning* (in-order interlock vs something
   else) still needs corroboration against a reference platform
   (`linux_bench.sh` on the Pi uses generic `stalled-cycles-backend`,
   different vocabulary — no direct overlap).
2. **README says 6 counters, device has 7.** Both 4-event sets fit either
   way; only relevant if the sets grow.
3. Every bench launch prints `ggml_backend_load_best: search path
   /data/local/tmp/../lib does not exist` — llama-bench stub noise, harmless.
4. Post-deep-sleep the phone bench at ~1.8 t/s vs ~8.3 t/s fresh —
   the temperature/frequency gate in the harness exists exactly for this.

## 7. The big one: wireless adb drop ⇒ silent data corruption

### Symptom

Run #1 (`--mode control`, 24 arms) launched, was killed by the tool's 2 h cap
mid-run, restarted, and the fresh run produced **three all-zero CSV rows**:

```csv
... control:simpleperf, 0, 0.0, 1050615.63, tg, 6, -1050615.63   # t1 reset to 0
... control:telemetry,  0, 0.0, 0.0, tg, 6, 0.0                  # zero boottime
```

`adb devices` showed nothing; even `ping 192.168.0.102` failed.

### Root cause

Two independently fatal flaws:

1. **Wireless adb drops mid-run on this device.** The adb TCP session to
   `192.168.0.102:5555` dies silently (phone deep-sleeps / WiFi power-save),
   often during a long `adb shell` bench call. The host only notices on the
   *next* call.
2. **`sh()` swallowed it.** Every harness adb call returned
   `sh(cmd, check=False)`, which passes an empty string back on any failure.
   `boottime()` → `0.0`, `parse_*` → empty. The harness kept "measuring" and
   wrote garbage rows without a peep.

### Fix (harness.py)

1. **Keepalive pinger** — daemon thread that runs `adb shell true` every
   5 s while the harness lives, holding the TCP session + WiFi alive:

   ```python
   keepalive()   # started in main() right after the adb presence check
   ```

2. **Reconnect-wrapped `sh()`** — if a call returns non-zero *and* the device
   is offline, try `adb connect`; if that succeeds, retry the call once:

   ```python
   def is_online():
       return (WIFI_ADDR in adb devices stdout
               and no "offline" before the serial line)

   if p.returncode != 0 and not is_online():
       reconnect()
       p = subprocess.run(full, ...)   # retry once
   ```

3. **Mid-bench drop detector** — an arm whose `t1 == 0` / empty `tps` with the
   device back online is now logged as FAILED and skipped, never recorded:

   ```python
   if is_online() and not tps:
       print(f"  !! {arm} FAILED - adb dropped, no benchmark captured")
       continue
   ```

4. **Startup reaping** — after reconnect, `pkill` orphaned on-device
   `llama-bench` from the dropped call before starting the next arm.

## 8. Successful control run (Run #3) — 24/24 arms clean

```bash
nohup /tmp/opencode/benchvenv/bin/python harness.py --mode control \
  > /tmp/opencode/control_run3.log 2>&1 & echo $!
```

- Battery 79% Discharging at start → 56% at the end (159.5 min)
- **24 arms, all with real `wall_s`, `entry_temp_mC` and `tps`** — zero
  corruption rows. The watchdog kept the session alive for the whole 2.7 h.
- One arm saw a long cooldown (189 s) and one hit a 508 s run → thermal
  throttling under sustained load, post-hoc removable.

Output: `out/run_20260807_233110` (manifest, `results_control.csv`,
`summary.md`, figures).

### Verdict (Pass C verdict in `summary.md`)

| arm | n | median t/s | IQR | vs bare |
|---|---|---|---|---|
| bare | 8 | 8.81 | 0.67 | — |
| simpleperf | 8 | 8.60 | 0.33 | **−2.4%** |
| telemetry | 8 | 8.07 | 0.64 | −8.4% (borderline) |

`simpleperf` sits well inside the noise band. `telemetry` is 8.4% below bare
but its IQR (7.44–8.14) overlaps bare's lower edge (~8.14) — read on the
boundary. The writeup should call out that telemetry's 128-rep run carries a
~1.3 kB Perfetto trace in the same window.

Note: the control arm is one config (`tg_t6_free`: 6 free threads, 128 tokens,
20 reps).

## 9. Completed Pass A sweep — the 33-arm run (Historical dataset)

This is the full-characterization baseline. **It is historical data: do not
rerun, rewrite, migrate, or recompute it.**

```bash
nohup /tmp/opencode/benchvenv/bin/python harness.py --mode sweep \
  --reps 20 --batches 3 --seed 1234 \
  > /tmp/opencode/sweep_run4.log 2>&1 & echo $!
```

Output: `out/run_20260808_194215` (UTC `2026-08-08T13:42:16Z`).

| aspect | value |
|---|---|
| passes | Pass A only — 11 configs × 3 batches, seed 1234 |
| device | Helio G81 Ultra / mt6768, battery **100% Discharging**, airplane **1** |
| coverage | **33/33 arms completed** — all valid, zero thermal timeouts, zero throttled reps (0/3 everywhere) |
| duration | ~6.1 h device-clock (first `t_start` → last `t_end`), ~4.9 h in `wall_s` bench time |
| energy | `energy_j` 0.41–1.20 kJ per arm, **26 269** telemetry samples total |
| artifacts | `results.json`/`.csv`, `summary.md`, 3 figures, **33 Perfetto traces + 33 telemetry CSVs** |

### Throughput summary (median over the 3 batches, per config)

| config | med t/s | batch medians |
|---|---|---|
| pp_t8_free | 16.83 | 16.48 / 16.83 / 17.21 |
| pp_t6_A55  | 15.97 | 15.58 / 15.97 / 15.98 |
| pp_t2_A75  |  8.93 |  8.55 /  8.93 /  9.07 |
| tg_t6_A55  |  7.97 |  6.65 /  7.97 /  8.37 |
| tg_t4_free |  7.55 |  6.97 /  7.55 /  7.58 |
| tg_t4_mix  |  7.50 |  7.24 /  7.50 /  7.79 |
| tg_t6_free |  7.09 |  6.83 /  7.09 /  8.16 |
| tg_t2_A55  |  6.32 |  6.16 /  6.32 /  6.39 |
| tg_t2_free |  6.19 |  5.67 /  6.19 /  6.29 |
| tg_t2_A75  |  5.74 |  5.71 /  5.74 /  6.40 |
| tg_t8_free |  4.72 |  4.64 /  4.72 /  4.89 |

### Schema caveat (important for analysis)

This run predates the current result schema. Each `results.json` row is the
**legacy format**: no `extra.valid`, no `attempt_id`, no `previous_attempts`,
no `energy_j_timestamped` / `energy_metric_used`, no `bench_json/` archive,
and no `schema_version` in the manifest. `tps` is the aggregate per batch
(one value per `rep_batch`, not per-rep samples). The current harness reads
it fine (`result_is_valid` treats non-empty `tps` as completed), and under
the new rules its `tokens_per_joule` is `energy_j`-derived — i.e. the legacy
estimate, matching what its rows say.

### Fuel/thermal notes

Battery 100% Discharging at start, airplane on. `pp_t2_A75` is the heavy
hitter (1189–1279 s wall / ~0.98–1.20 kJ per arm): the 2-big-core prefill
config dominates wall time and energy. Model sha1 `89c8d7f7...` and
llama-bench sha1 `1dca7537...` were recorded in the manifest at run time.

## 10. Completed Pass B — the PMU counters run (Historical dataset)

```bash
nohup /tmp/opencode/benchvenv/bin/python harness.py --mode counters \
  --reps 20 --batches 3 --seed 1234 \
  > /tmp/opencode/passb_run.log 2>&1 & echo $!
```

Output: `out/run_20260809_230355`. 16/16 arms valid, zero multiplexing, 0
timeouts, done in 67.5 min. Prefill configs skipped by design (counters on
decode only).

| aspect | value |
|---|---|
| configs | 8 tg configs × 2 event sets = 16 arms, seed 1234 |
| device | Helio G81 Ultra / mt6768, battery 100% Discharging, airplane 1 |
| schema | v3 (attempt IDs, per-rep `samples_are_per_rep`, `bench_json/` archive) |
| events | 4-event sets: `cpu-cycles`, `instructions`, `raw-stall-backend`, `raw-ll-cache-miss-rd` (core) and A55 stall events (a55) |

### Key counter results (from `summary.md` / `derived.csv`)

- A55 IPC 0.63–0.98, A75 IPC 1.44–2.04 (per-core counts, user-mode only)
- A55 interlock stalls 18–20% of cycles, ldcache 6.5–10.3% — interlock/ldcache
  ratio ~1.8–2.9, i.e. in-order dependency dominates A55 stalls
- DRAM read ~1.25–3.8 GB/s; A75 carries 60–100% of decode memory traffic
  (100% for `tg_t2_A75`, as expected)

> Caveat: the `core` and `a55` event sets are different invocations, so
> ilock/ldcache and DRAM rows are from separate runs, not the same one.

## 11. Current state & next steps

- `out/run_20260807_233110`: control run (24/24 arms) — Pass C verdict done
- `out/run_20260808_194215`: **historical 33-arm Pass A** baseline (legacy
  schema, see §9) — the canonical throughput/energy dataset
- `out/run_20260809_230355`: **Pass B counters** (16/16 arms, schema v3,
  zero multiplexing) — PMU derivations in `derived.csv`
- harness.py carries: energy scales (mA/mV), HAL temp fallback, non-blocking
  `sh`, reconnect+keepalive, perfetto `-o`, simpleperf `-o`, orphan reaping,
  mid-bench drop detection, plus the later correctness passes (attempt IDs,
  non-retry benchmark execution, timestamped energy)
- All 6 PMU event names verified counting; `--per-core` output matches
  `parse_simpleperf` (see §6b)
- Next: write up the analysis — `analyze.py` output exists for all three
  runs; assemble the report (throughput, per-cluster IPC/stalls, A75 vs A55,
  energy, control verdict)

## 12. Workflows (copy-paste)

### Fuel-gauge validation (wireless-friendly)

```bash
adb push /tmp/opencode/energy_probe.sh /data/local/tmp/
adb shell 'rm -f /data/local/tmp/energy_probe.log; \
  sh /data/local/tmp/energy_probe.sh </dev/null >/dev/null 2>&1 &'
adb shell 'grep -cE "^[0-9]+ " /data/local/tmp/energy_probe.log'   # poll to 240
adb pull /data/local/tmp/energy_probe.log /tmp/opencode/
# ratio ~1.0 => current_now in mA; ~0.001 => in uA
```

### Survivable long run

```bash
nohup /tmp/opencode/benchvenv/bin/python harness.py --mode control \
  > /tmp/opencode/control_run.log 2>&1 & echo $!
# monitor (python buffers stdout when not a tty, log stays empty):
wc -l < $(ls -t out/run_*/results_control.csv | head -1)
```

### Clean reset

```bash
pkill -9 -f harness.py
adb shell 'pkill -9 -f llama-bench; pkill -9 -f sampler.sh; pkill -9 -f perfetto'
rm -rf out/run_*
```

### After any adb reconnect

```bash
adb tcpip 5555 && adb connect 192.168.0.102:5555
adb shell 'settings put global airplane_mode_on 1'   # reapply both:
adb shell input keyevent KEYCODE_SLEEP
```

## 13. Implemented `--bench` (schema v4) — A/B implementation support

2026-08-10: added the benchmark-implementation selector so the same harness
can measure either binary with identical methodology. This is the "Season 2"
change: everything below supersedes the single-implementation assumption.

### The change (harness.py)

- `--bench {llama-bench,llama-bench-kai}`, CLI default `None`:
  - new run + omitted  -> `llama-bench`
  - `--resume` + omitted -> the benchmark recorded by the resume
    directory's manifest (schema-4 reads `benchmark.name`; legacy schema-3
    is treated as `llama-bench`)
  - explicit + resume -> must MATCH the manifest, else hard exit
    (`Refusing to mix benchmark implementations.`), before any benchmark
    runs
- `BENCHMARKS` mapping (name -> on-device filename); `bench_cmd(bench_name,
  ...)` builds the command; the two inline `simpleperf stat -- ./<exe>`
  call sites (Pass B + Pass C simpleperf arm) use the same mapping — no
  hardcoded `./llama-bench` remains in any execution path
- `RESULT_SCHEMA_VERSION` 3 -> 4 (benchmark is now experiment identity)
- `manifest["benchmark"] = {name, filename, path, sha1, version}`; version
  comes from `./<exe> --help | head -1`, never hardcoded. Legacy
  `llama_bench_sha1` / `llama_bench_version` keys kept, populated from the
  selected executable (so old analysis scripts still work)
- every result row carries `extra["benchmark"] = <name>`; `bench_json/`
  filenames unchanged (the manifest disambiguates)
- startup validation: the selected binary must exist and `--help` must
  return rc=0 before Pass A/B/C; error names the selected executable
- `result_key()` unchanged: benchmark identity is enforced at the
  experiment/manifest level, not per-measurement

### Verified on device (2026-08-10)

- `probe.sh --bench llama-bench-kai` -> same CLI surface as vanilla:
  `-m/-p/-n/-t/-r/-o json`, `-C <mask> --cpu-strict 1` all present
- Kai JSON output byte-compatible with vanilla (`samples_ts`,
  `samples_ns`, `avg_ts`) — existing parser reused unchanged, no Kai
  special-casing
- full smoke: `--mode control --control-n 1 --bench llama-bench-kai`
  6/6 arms valid, all tagged `extra.benchmark=llama-bench-kai`, verdict
  computed (12.7 min)
- `python3 test_harness.py`: 62/62 green (17 new tests covering command
  building, pass propagation, the resume matrix, manifest regression)

### Run matrix for the A/B (this is what the pending runs are FOR)

| benchmark | sweep (Pass A) | counters (Pass B) | control (Pass C) |
|---|---|---|---|
| llama-bench    | same seed, same matrix | same seed | same seed |
| llama-bench-kai | same seed, same matrix | same seed | same seed |

All passes share one outdir per benchmark (`--mode all`), one seed (1234),
one model, one thermal policy. `--resume` guarantees a run dir never mixes
implementations.

## 14. Season 2 run plan — full A/B on the CURRENT device files

### CRITICAL finding before any run

The device files changed on 2026-08-10, so the Season-1 datasets
(§8/§9/§10) are NOT comparable to anything run now:

| file | S1 (Aug 4) sha1 | S2 (Aug 10) sha1 |
|---|---|---|
| model.gguf | `89c8d7f7...` (491 MB) | `6cb61065...` (429 MB) |
| llama-bench | `1dca7537...` (17.50 MB) | `a69fac33...` (17.35 MB) |

=> the old llama-bench (+model) sweep must be REDONE to serve as the
vanilla arm of the A/B; the S1 files are closed history and stay untouched.

### Planned invocations (in this order, both on the same seed 1234)

```bash
# vanilla arm (Pass A + B + C in one dir)
rm -rf out/llama_bench_s2
nohup /tmp/opencode/benchvenv/bin/python harness.py \
  --mode all --reps 20 --batches 3 --seed 1234 \
  --bench llama-bench --out out/llama_bench_s2 \
  > /tmp/opencode/s2_vanilla.log 2>&1 & echo $!

# kai arm (Pass A + B + C in a separate dir)
rm -rf out/llama_bench_kai_s2
nohup /tmp/opencode/benchvenv/bin/python harness.py \
  --mode all --reps 20 --batches 3 --seed 1234 \
  --bench llama-bench-kai --out out/llama_bench_kai_s2 \
  > /tmp/opencode/s2_kai.log 2>&1 & echo $!
```

Estimated duration: Pass A ~6 h, Pass B ~1 h, Pass C ~40 min per arm
(~7.5-8 h each, ~15-16 h back to back). Requires battery discipline.

### Battery/hygiene plan

- start each arm at 100% (charge, unplug, then run) — the capacity sensor
  read 74% at planning time; both arms cannot run back-to-back on it
- airplane mode ON, screen OFF, unplugged (wireless adb) for every arm
- llama-bench-kai at the time of writing was mode `770` (no +x) — needs
  `adb shell chmod 755 /data/local/tmp/llama-bench-kai` (already done;
  verification: `./llama-bench-kai --help` rc=0 on 2026-08-10)

### Status at time of writing

- device: Helio G81 Ultra, battery 74% Discharging, airplane 1, screen Asleep
- `-rwxr-xr-x llama-bench` / `-rwxrwx--x llama-bench-kai` / `model.gguf`
  (429 MB) staged in `/data/local/tmp`
- S1 outdirs intact: `out/run_20260807_233110` (control),
  `out/run_20260808_194215` (sweep S1), `out/run_20260809_230355` (counters
  S1)

## 15. Workflows (Season 2, copy-paste)

### A/B smoke, one block, no telemetry (5-15 min, proof of wiring)

```bash
/tmp/opencode/benchvenv/bin/python harness.py \
  --mode control --control-n 1 --reps 2 --seed 7 \
  --bench llama-bench-kai --out /tmp/opencode/kai_smoke
```

### Forked full run (the real matrix)

```bash
# vanilla first or kai first; NEVER interleave the two in one outdir
nohup /tmp/opencode/benchvenv/bin/python harness.py \
  --mode all --reps 20 --batches 3 --seed 1234 \
  --bench llama-bench --out out/llama_bench_s2 \
  > /tmp/opencode/s2_vanilla.log 2>&1 & echo $!
```

```bash
nohup /tmp/opencode/benchvenv/bin/python harness.py \
  --mode all --reps 20 --batches 3 --seed 1234 \
  --bench llama-bench-kai --out out/llama_bench_kai_s2 \
  > /tmp/opencode/s2_kai.log 2>&1 & echo $!
```

### Resume guards (verify before trusting a mixed dir)

```bash
# must refuse:
python3 harness.py --bench llama-bench --resume out/llama_bench_kai_s2
python3 harness.py --bench llama-bench-kai --resume out/llama_bench_s2
# legacy schema-3 dirs are llama-bench; resuming them as kai must refuse:
python3 harness.py --bench llama-bench-kai --resume out/run_20260808_194215
# these must succeed:
python3 harness.py --resume out/llama_bench_s2
python3 harness.py --resume out/llama_bench_kai_s2
```
---

# PART II — the device-side pipeline (2026-08-11 → 12)

Everything above this line describes the **adb-driven harness and is now
historical**. The loop no longer runs on the laptop. Sections 1–15 are kept
because their crash diagnoses are still true of the device; the workflows in
them are not.

Two corrections to Part I before anything else:

- **§3/§6/troubleshooting: `LD_LIBRARY_PATH` and the libssl workaround are
  obsolete.** The staged binaries are fully static; nothing needs
  `libssl.so.3`/`libcrypto.so.3` and nothing needs `LD_LIBRARY_PATH`. The
  runner leaves it unset (`LDPATH=` opts back in for a dynamic build).
- **§9/§10 conclusions about A55-vs-A75 are invalid.** See §17.

## 16. Why the loop moved onto the phone

The adb harness blocked inside one `adb shell` call for up to an hour per arm.
Wireless adb on this device dies after 3–4 hours, and `run_benchmark()`
deliberately never retried (a retry after a lost connection risks recording a
second measurement as the first), so a drop **stopped the run**.

Confirmed during this work: the drop still happens **with a Termux wakelock
held**, so §7's deep-sleep explanation is wrong — it is adbd/TCP. When the WiFi
path dies, the LAN address gives "No route to host" while Tailscale still
answers.

Moving the loop on-device also removed `measurement_uncertain` entirely: the
process that launches llama-bench reads its own exit code, so every outcome is
known — which makes re-queuing a failed arm safe for the first time.

Layout: `plan.py` / `receiver.py` / `ingest.py` / `resultlib.py` / `analyze.py`
on the PC, `runner.sh` / `uploader.sh` / `preflight.sh` / `lib.sh` on the
phone. See README.md. adb is used only to copy files and start the runner
detached; proven by `adb kill-server` mid-run, after which arms and heartbeats
kept arriving over TCP.

## 17. `-C/--cpu-mask` is ignored on Android (invalidates §9/§10 cluster claims)

`taskset` was used as the control, which separates "the kernel cannot pin" from
"llama-bench is not asking it to". 2-thread decode, A75 share of cycles:

| invocation | A75 share |
|---|---|
| no mask at all | 98.8 % |
| `-C 0x03 --cpu-strict 1` | 99.5 % |
| `taskset 03` | **0.1 %** |
| `taskset c0` | **100.0 %** |

The kernel pins perfectly; llama-bench's `-C` does nothing. Root cause is
upstream: `ggml-cpu.c` guarded the affinity code with
`#elif defined(__gnu_linux__)`, which Clang does not define for Android target
triples, so the mask hit an unsupported-platform stub. Fixed in llama.cpp
PR #26838, merged 2026-08-10 — one day before these runs, and after the staged
binary was built.

**Consequence for Part I:** every A55-vs-A75 config in §9/§10 measured the same
thing as its unmasked twin. "100 % A75 traffic for tg_t2_A75, as expected" was
meaningless — tg_t2_A55 also showed 99.5 %.

The runner now masks with `taskset` (`MASK_MODE=taskset`, the default) and
`preflight.sh` gates on it. After the fix the same probe reads 0.1 %, and the
sweep shows a real 1.92× separation (tg_t2_A75 11.42 vs tg_t2_A55 5.96 t/s)
where Part I showed 5.74 vs 6.32 — indistinguishable and backwards.

## 18. The 850 MHz clamp is real (PMU-confirmed)

`policy6/scaling_cur_freq` reads a constant 850000 under load. That is the
**lowest** entry in `scaling_available_frequencies`, against a
`cpuinfo_max_freq` of 2000000. `cpuinfo_cur_freq` is permission-denied, so the
PMU was used as ground truth:

    10 s busy loop pinned to cpu7 -> 8,386,773,177 cpu-cycles:u = 0.839 GHz
    scaling_cur_freq              -> 0.850 GHz          (agree to 1.3 %)

So the sysfs node is honest: the A75 really does run at its minimum OPP, ~42 %
of rated clock. Ruled out: thermal (`Thermal Status: 0`), battery saver
(`low_power=0`), uclamp (`max=1024`), cpuset (root, not `background`).
`scaling_max_freq` is not writable and `/proc/ppm` is unreadable — a vendor
policy shell uid cannot see or change. Would need root, possibly Shizuku.

**Treat absolute t/s as a lower bound.** Every relative comparison is
unaffected: all arms ran under the identical cap.

This also means the `throttled` column in `summary.md` is meaningless — the
detector flags samples below 90 % of the *observed* ceiling, and a constant
series has none. `preflight.sh` warns rather than gates, because a clock cap
affects every arm equally and must not block an A/B.

## 19. Device quirks found the hard way

- **toybox `sh` arithmetic is 32-bit signed.** Cycle counts are billions:
  `$(( 949244217 + 6491805586 ))` = `-1148884789`. This silently turned the
  pinning gate into a no-op reporting "counted no cycles at all". All such
  arithmetic now stays inside `awk`.
- **toybox `nc -q` does not work as documented.** nc exits the instant stdin
  reaches EOF and discards the peer's reply. Without a trailing `sleep` to hold
  stdin open, the ack is never seen, delete-on-ack never fires, and the outbox
  grows forever while every arm is in fact delivered. `device/stubs/nc`
  reproduces this deliberately so the workaround stays tested.
- `timeout N VAR=value cmd` exits 127 — `timeout` treats the assignment as the
  program name, which looks exactly like a missing binary. Use `env`.
- `timeout N some_shell_function` cannot work; timeout execs a binary.
- Unscoped `pkill -f <pattern>` matches any process merely *mentioning* the
  string. Reaping is now by tracked PID only.
- `cd X && ... &` in an adb shell string still hangs (§4c) — rediscovered by
  writing it again in `deploy.sh`.
- No `curl`, no `wget`, no `busybox`; toybox `nc` only. Transport is raw TCP
  with a line-framed header and a sha256.
- `/sys/power/wake_lock` is denied to shell uid: suspend can be detected, not
  prevented. `termux-wake-lock` (Termux app, not Termux:API) does prevent it.
- Airplane mode: `settings put global airplane_mode_on 1` works from shell and
  leaves WiFi up, as §2 always said. Do **not** try to verify it via
  `getprop gsm.network.type` or `dumpsys telephony.registry` — both report
  cached "last known" values that never refresh on toggle, which makes a
  working airplane mode look broken.

## 20. Suspend detection, calibrated twice

Sampler cadence gaps are the only suspend signal available without root.
Threshold history:

- 20 s, from the Part I sweep whose worst legitimate gap was 4.38 s.
- **Wrong.** With the faster Q4_0 model, 8-thread configs starve the sampler
  far harder: kai `tg_t8_free.b2` 22.30 s (rejected — twice), kai
  `tg_t8_free.b0` 16.37 s, vanilla `pp_t8_free.b0` **19.46 s (accepted by
  0.54 s)**. All completed with rc=0 and 20 valid samples.
- Now **60 s**, ~2.7× the worst observed starvation. Energy stays separately
  protected: gaps beyond 30 s are excluded from the integral and counted.

Also changed: `ingest.py` is now **authoritative over the device's own flag**
rather than OR-ing with it. The device decides once with whatever threshold it
shipped; ingest can be fixed and re-run over the same inbox forever. OR-ing
made a device-side false positive permanent — it discarded a good arm twice and
could only have been undone by re-running the benchmark.

## 21. Season 2 A/B — both matrices complete

Same seed (1234), same model (`6cb61065`), same thermal policy; only the binary
differs. 97 arms each: 33 sweep + 16 counters + 48 control.

| | llama-bench | llama-bench-kai |
|---|---|---|
| bench sha1 | `a69fac33` | `36364141` |
| arms | **97/97 valid** | **97/97 valid** |
| span | 9.4 h | 9.8 h |

Battery: Pass A alone was 3.31 h / 20 % — far cheaper than the 6.1 h / 53 %
projected from Part I, because the Q4_0 model is roughly twice as fast.

### Throughput (median t/s over 3 batches)

| config | vanilla | kai | kai/van |
|---|---|---|---|
| pp_t8_free | 43.32 | 47.89 | **1.11x** |
| pp_t6_A55 | 41.97 | 43.45 | 1.04x |
| pp_t2_A75 | 24.30 | 23.45 | 0.97x |
| tg_t4_mix | 14.60 | 13.37 | 0.92x |
| tg_t4_free | 14.11 | 13.44 | 0.95x |
| tg_t6_free | 13.98 | 10.68 | 0.76x |
| tg_t6_A55 | 11.99 | 9.56 | 0.80x |
| tg_t2_A75 | 11.42 | 11.29 | 0.99x |
| tg_t2_free | 11.09 | 11.09 | 1.00x |
| tg_t2_A55 | 5.96 | 6.77 | 1.14x |
| tg_t8_free | 5.49 | 1.13 | **0.21x** |

KleidiAI wins prefill (+11 % at 8 threads, which is what its GEMM kernels
target) and is flat-to-worse on decode. `tg_t8_free` collapses to 0.21× —
reproduced across all three batches, and the reason that arm ran 2640 s against
vanilla's 474 s. Worth investigating with the Pass B counters already collected.

### Pass C — the harness is not free

Block-paired deltas vs bare, 8 blocks:

| config | arm | median delta |
|---|---|---|
| tg_t2_A75 | simpleperf | −0.68 % (within tolerance) |
| tg_t6_free | simpleperf | +0.68 % (within tolerance) |
| tg_t2_A75 | telemetry | −2.52 % (above) |
| tg_t6_free | telemetry | **−8.27 % (above)** |

simpleperf is free; the sysfs sampler is not. Part I measured −8.4 % for the
same arm, so it reproduces. Every Pass A arm carries telemetry (that is where
energy comes from), so those throughput numbers sit ~2–8 % below what the bare
binary does. The A/B is unaffected — both implementations pay it.

## 22. Analysis needs a venv

System python is externally managed, so `analyze.py` silently degrades to
tables-only without matplotlib and writes no figures:

```bash
python3 -m venv .venv && .venv/bin/pip install matplotlib
.venv/bin/python analyze.py out/llama-bench
```

Produces `fig_throughput.png`, `fig_timeline.png`, `fig_stalls.png`,
`fig_energy.png` alongside `summary.md` and `derived.csv`.
