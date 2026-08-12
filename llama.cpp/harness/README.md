# lbench — device-side llama.cpp benchmarking for unrooted Android

The phone runs the benchmark loop. The laptop generates the plan, receives the
results, and analyses them. **adb is not in the loop** — it copies files once,
starts the runner detached, and is then free to die for the rest of the run.

## Why it works this way

The previous harness drove every arm from the laptop over adb, blocking inside
a single `adb shell` call for up to an hour while llama-bench ran. Wireless adb
on this device dies after 3–4 hours. When it died mid-benchmark the arm was
lost as `adb_disconnect_during_benchmark`, and because re-running a measured
command risks silently recording a second measurement as the first, the harness
deliberately refused to retry — so the whole run stopped and needed a human.

Moving the loop on-device fixes more than uptime. `measurement_uncertain`
existed only because the laptop could not tell whether a benchmark it lost
contact with had completed. The process that launches llama-bench now observes
its own exit code, so every outcome is known — which makes re-queuing a failed
arm safe for the first time.

Measured on this device, the drop is **not** deep sleep: it still happens with
a Termux wakelock held. When the WiFi path dies the LAN address returns "No
route to host" while Tailscale still answers, so delivery falls back to it.

## Layout

```
PC side
  plan.py          generate the run matrix (seeded, reproducible)
  receiver.py      TCP sink :9000 — verify checksum, land bytes, ack
  ingest.py        inbox/*.tar -> results{,_counters,_control}.json
  resultlib.py     the result model + every pure function over it
  analyze.py       results -> summary.md + figures
  deploy.sh        push, preflight, launch detached
  e2e_dryrun.sh    whole pipeline on the laptop, no phone

device side (pushed to /data/local/tmp)
  runner.sh        THE LOOP: cooldown -> bench -> stage -> commit -> next
  uploader.sh      drains the outbox to the PC, retries forever
  preflight.sh     validates the apparatus, refuses to start if it is broken
  lib.sh           shared helpers
  sampler.sh       on-device sysfs sampler (200 ms cadence)
  trace_config.pbtx  perfetto config
  stubs/           fake binaries so the loop is testable on a laptop
```

## Per-session setup

`deploy.sh` does not put the device into measurement hygiene — it only checks
it. Before each session:

```bash
./deploy.sh --prep      # bluetooth off, screen off, verify PC reachable
./deploy.sh --status    # read-only: battery, runner, undelivered arms
```

`--prep` runs **on-device and detached** on purpose. Enabling airplane mode
drops WiFi, and WiFi is the only path off this phone (Tailscale rides it,
mobile data is off). Driven over adb, a WiFi failure would kill adb mid-
sequence with no way to undo it remotely. Running locally means the rollback
always executes, and it rolls back automatically if the PC becomes unreachable.

**Two things `--prep` cannot do for you:**

1. **Unplug the charger.** Charging invalidates energy *and* holds the phone at
   43–45 °C, which keeps the 42 °C thermal gate shut so arms are skipped rather
   than measured. Charge to 100 %, then unplug.
2. **Nothing else.** Airplane mode is handled by `--prep`: writing
   `airplane_mode_on` from the shell drops the mobile radio and leaves WiFi
   up, which is what the hygiene procedure has always relied on. Do not try to
   confirm it via `getprop gsm.network.type` or `dumpsys telephony.registry` —
   both are cached "last known" values that do not refresh on toggle and will
   make a working airplane mode look broken.

Also worth doing: stand the phone up rather than laying it flat, so it can
shed heat between arms.

## Quickstart

```bash
# 1. receiver + a short run on the real device
./deploy.sh --mode sweep --reps 2 --batches 1 --smoke

# 2. build results as arms arrive (adb may be dead by now; that is fine)
python3 ingest.py out/run_<ts> --watch

# 3. tables and figures
python3 analyze.py out/run_<ts>

# full matrix, phone UNPLUGGED
./deploy.sh --mode all --reps 20 --batches 3 --seed 1234 \
            --pc "192.168.0.104 100.100.47.53"
```

`deploy.sh` returns as soon as the runner has the lock. After that adb is
optional: watch `out/run_*/inbox/.heartbeat` or the receiver log.

## A/B between implementations

One run directory = one benchmark implementation, enforced. `--bench` selects
it, it lands in the directory name and in `manifest.kv`, every arm carries it
in `meta.kv`, and `--resume` refuses to switch implementations underneath an
existing dataset.

```bash
./deploy.sh --bench llama-bench     --mode all --seed 1234
./deploy.sh --bench llama-bench-kai --mode all --seed 1234   # same seed
```

Same seed, same model, same thermal policy — only the binary differs.

## Time and battery budget

Measured on this device from the historical runs (reps=20, 8.65 %/h drain):

| pass | arms | hours | battery |
|---|---|---|---|
| A sweep | 33 | 6.1 | 53 % |
| B counters | 16 | 1.1 | 10 % |
| C control (`--control-n 8`) | 48 | 5.3 | 46 % |
| **total per implementation** | **97** | **12.6** | **109 %** |

**A full matrix does not fit in one charge** (100 %→20 % is ~9.3 h of budget),
and charging invalidates energy, so it must be split across sessions.
`done.ledger` survives, so `--resume` continues where it stopped.

Pass C measures *harness overhead* — a property of the apparatus, not of the
benchmark implementation — so running it once rather than per-implementation
is usually defensible and saves 5.3 h.

## The rule everything follows

**The benchmark loop never blocks on anything off-device.** `runner.sh` writes
finished arms into an outbox and moves on. `uploader.sh` is a separate process
that drains it. A PC that is asleep, firewalled or gone cannot stall a single
measurement — arms queue on the phone and drain when it returns.

Two queues, and the priority between them matters:

| queue | contents | per arm | policy |
|---|---|---|---|
| `outbox/` | bench JSON + telemetry CSV + `meta.kv` | ~30 KB | always drained first |
| `outbox_bulk/` | perfetto trace | ~16 MB | best effort, capped at 600 MB, oldest evicted |

A 16 MB diagnostic must never delay or displace the 30 KB that is the actual
result. An evicted trace is recorded as `trace_evicted=1`, never silently lost.

The device deletes its only copy **only** after the PC has verified the
checksum and said so.

## Transport

Raw TCP with a line-framed header. The phone has no `curl`, no `wget`, no
`busybox` — only toybox `nc`.

```
ARM <arm_id> <sha256> <nbytes>\n   then exactly <nbytes> bytes
  -> OK <arm_id>       stored and verified; device may delete
  -> ERR <reason>      nothing stored; device MUST keep its copy
HB <text>\n            status heartbeat (every 60 s)
PING\n                 liveness probe for address selection
```

**The trailing `sleep` in `send_frame` is load-bearing.** Measured on toybox
0.8.12-android: `nc` exits the instant stdin reaches EOF and discards the
peer's reply, and its documented `-q` flag does *not* change that. Without the
sleep the ack is never seen, delete-on-ack never fires, and the outbox grows
forever while every arm is in fact being delivered. `device/stubs/nc`
reproduces this behaviour deliberately so the workaround stays tested.

## Preflight gates

`preflight.sh` runs before the matrix and refuses to start on failure
(`FORCE=1` overrides). Its report is uploaded *first*, so a failure reaches you
without adb.

Two gates exist because the previous dataset was invalidated by faults nothing
reported:

- **pinning** — masking is verified by running masked to `0x03` under
  `simpleperf --per-core` and asserting the A75 cores stay idle. Whichever
  mechanism `MASK_MODE` selects is what gets probed.
- **frequency** — `scaling_cur_freq` must actually vary under load, otherwise
  `analyze.py`'s throttle detector (samples below 90 % of the observed ceiling)
  can never fire and "0/3 throttled" means nothing.

**Pinning passes** with the default `MASK_MODE=taskset` (0.1% of cycles leak
to the A75). It **fails** with `MASK_MODE=cpumask`, because llama-bench's `-C`
is silently ignored on Android before llama.cpp
[PR #26838](https://github.com/ggml-org/llama.cpp/issues/26838) (merged
2026-08-10): `ggml-cpu.c` guarded the affinity code with
`#elif defined(__gnu_linux__)`, which Clang does not define for Android target
triples, so the mask hit an unsupported-platform stub. Switch to
`MASK_MODE=cpumask` once a binary containing the fix is staged.

**The frequency gate still FAILS** — see `evidence/`. If that is a real clamp
rather than a reporting artefact, every throughput number is being collected
at roughly 40 % of the rated clock.

## Failure handling

Every arm ends in a named state, never a plausible-looking number:

| condition | `fail_reason` |
|---|---|
| gate never reached target temp | `thermal_gate_timeout` |
| killed at the wall clock | `benchmark_timeout` |
| nonzero exit | `benchmark_failed` |
| exited 0, no JSON appeared | `bench_json_missing` |
| JSON unparseable | `bench_json_invalid` |
| parsed, no usable samples | `bench_no_samples` |
| sampler cadence gap > 20 s | `suspend_during_measurement` |

Definite failures are re-queued **once**, at the end of the plan. Charging
invalidates *energy* only — throughput survives, `tokens_per_joule` is dropped
with `energy_invalid_reason` recorded.

`done.ledger` survives a reboot, so re-running `deploy.sh --resume` continues
where it stopped without repeating finished work.

## Perfetto traces

Not in this repo — 1.2 GB raw across the two matrices, and nothing in
`analyze.py` reads them (the DVFS/thermal figure comes from the telemetry
CSVs). They are diagnostic: `sched_switch` evidence for which cluster each
thread actually ran on.

They ship as **GitHub Release assets**, which do not count toward repo size
and are not in git history, so a `git clone` stays instant for anyone who only
wants the code.

| asset | arms | download |
|---|---|---|
| `llama-bench-sweep-traces.tar.zst` | 11 (one per config, batch 0) | 130 MB |
| `llama-bench-control-traces.tar.zst` | 16 (Pass C telemetry arms) | 95 MB |
| `llama-bench-kai-sweep-traces.tar.zst` | 11 | 133 MB |
| `llama-bench-kai-control-traces.tar.zst` | 16 | 130 MB |

```bash
gh release download traces-v1 -p 'llama-bench-sweep-traces.tar.zst'
mkdir -p out/llama-bench/traces
zstd -dc llama-bench-sweep-traces.tar.zst | tar -xf - -C out/llama-bench/traces
```

Verify against `SHA256SUMS`, also attached to the release. The control bundles
are 8 repeats each of the same two configs, so the sweep bundles are the ones
worth fetching first.

Rebuild them from a local `out/*/traces/` with:

```bash
tar -C out/<run>/traces -cf - $(cd out/<run>/traces && ls -1 sweep.*) \
  | zstd -10 -T0 -o dist/<run>-sweep-traces.tar.zst
```

## Testing

```bash
python3 -m unittest discover -p 'test_*.py'   # 118 tests
device/test_runner.sh                          # 35 device scenarios
./e2e_dryrun.sh                                # 14 end-to-end, no phone
```

`runner.sh` is driven entirely by `$DEV`, `$PATH`, `$BAT_DIR` and
`$THERMAL_DIR`, so the whole loop runs on a laptop against a fake device tree
with stub binaries. Nothing touches the phone until `deploy.sh`.

## Device constraints (all verified, not assumed)

- no `curl` / `wget` / `busybox`; toybox `nc` only
- no Python at shell uid, and **Termux is disqualified for the runner**: the
  same binary measured 11.58 t/s in Termux vs 13.96 t/s from `/data/local/tmp`,
  a 21 % difference from cgroup placement alone, and a child inherits its
  parent's cgroup
- `/sys/power/wake_lock` is denied to shell uid — suspend can only be detected,
  not prevented. `termux-wake-lock` (Termux app, not Termux:API) prevents it.
- `/sys/class/thermal/*/temp` is SELinux-gated; `temp_mC` falls back to the
  ThermalHAL via `dumpsys`
- perfetto config must live in `/data/misc/perfetto-configs`, output under
  `/data/misc/perfetto-traces`
- **toybox `sh` arithmetic is 32-bit signed.** Cycle counts are billions;
  `$(( 949244217 + 6491805586 ))` wraps to `-1148884789`. All such arithmetic
  stays inside `awk`.
- the staged binaries are fully static — no `LD_LIBRARY_PATH`, no libssl
- llama-bench `-C/--cpu-mask` is a no-op on Android before llama.cpp PR #26838;
  masking goes through `taskset`, which the kernel honours exactly
