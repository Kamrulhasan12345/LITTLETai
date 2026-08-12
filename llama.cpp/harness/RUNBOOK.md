# Runbook — running a preset validation session

Everything below is one session on one phone. Roughly **40 minutes** of wall
clock for both binaries, about **5% of battery**.

For the full 97-arm matrix instead, see `README.md` — that is 12.6 h and does
not fit in one charge.

All commands run from `llama.cpp/harness/`.

---

## 0. Before the keyboard

Two physical things, both of which have silently ruined a run before:

1. **Unplug the charger.** Charging invalidates energy *and* holds the phone at
   43–45 °C, which keeps the 42 °C thermal gate shut — every arm then records
   `thermal_gate_timeout` instead of a measurement.

   You do **not** need 100%. Both runs cost about 5%; anything above ~30% is
   fine. The "charge to 100% first" note in `README.md` is for the full matrix,
   which needs 109% of a charge.

2. **Stand the phone upright**, not flat on a desk, so it sheds heat between
   arms. And make sure **Termux is running with a wakelock** — `/sys/power/wake_lock`
   is denied to shell uid, so Termux is the only thing that prevents suspend.
   `preflight.kv` records `wakelock=termux_held` when it is working.

---

## 1. Check state — read-only, changes nothing

```bash
./deploy.sh --status
```

Look for: battery discharging, no runner already holding the lock, and
**0 undelivered arms**. If arms are pending, they exist nowhere else — drain
them before starting a new pass, or you will be asked for `--force-clear` and
lose them.

`deploy.sh` does not push the binaries or the model. They must already be at
`/data/local/tmp`:

```bash
adb shell 'ls -la /data/local/tmp/llama-bench* /data/local/tmp/model.gguf'
```

---

## 2. Device hygiene

```bash
./deploy.sh --prep
```

**adb will probably drop and reconnect. That is expected.** `--prep` runs
on-device and detached precisely because enabling airplane mode drops WiFi, and
WiFi is the only path off this phone — driven over adb, a failure mid-sequence
would leave no way to undo it remotely. Running locally means the rollback
always executes, and it self-heals if the PC becomes unreachable.

It waits ~25 s and prints `verdict=OK`. **If it does not say OK, stop and read
the output** rather than continuing with `--force`.

---

## 3. Run — stock binary (~14 min, 7 arms)

```bash
./deploy.sh --bench llama-bench --mode presets --reps 5 --batches 1 \
            --out out/presets_stock
```

Returns as soon as the runner has the lock. **After this, adb is optional** —
results come back over TCP to `receiver.py`, which `deploy.sh` starts for you.

In a second terminal, build results as arms land:

```bash
.venv/bin/python ingest.py out/presets_stock --watch
```

When it finishes:

```bash
.venv/bin/python analyze.py out/presets_stock
```

Use `.venv/bin/python`, **not** bare `python3` — the latter silently produces
tables with no figures.

---

## 4. Run — KleidiAI binary (~21 min)

Longer only because `tg_default` runs at ~1.6 t/s and takes 9 minutes on its
own. That arm is the point of the exercise.

```bash
./deploy.sh --bench llama-bench-kai --mode presets --reps 5 --batches 1 \
            --out out/presets_kai
.venv/bin/python ingest.py  out/presets_kai --watch
.venv/bin/python analyze.py out/presets_kai
```

One run directory = one benchmark implementation, enforced. Never point both
binaries at the same `--out`: the whole value of the A/B is that the two arms
are otherwise identical, and a directory holding both cannot be told apart
afterwards.

---

## 5. Give the phone back

```bash
./deploy.sh --unprep
```

Restores radios and screen settings.

---

## 6. What to look for

In `out/*/summary.md`, the throughput table is sorted by median t/s.

**`tg_default` (8 threads) must be last.** That is the whole claim. Expect
roughly 2.6× on stock and 11× on KleidiAI between it and the best preset.

Then check `preflight.kv` before trusting absolute numbers:

```bash
grep -E 'freq_|cpuinfo_max' out/presets_stock/preflight.kv
```

`freq_policy0_max` has been observed at both **850000** (clamped, roughly half
rated clock) and **1500000** (unclamped). Absolute t/s differs by 40–70% between
those two regimes, so **never compare numbers across runs with different
clamp state**. Every comparison must be same-run and same-binary.

---

## Failure modes seen in practice

| symptom | cause | fix |
|---|---|---|
| every arm `thermal_gate_timeout` | charger plugged in, or phone lying flat | unplug, stand it up |
| `deploy: N undelivered arm(s)` | previous session ended with a full outbox | drain first — those measurements exist nowhere else |
| runner never takes the lock | stale lock from a killed runner | `adb shell tail -20 /data/local/tmp/runner.log` |
| tables render but no figures | used `python3` instead of `.venv/bin/python` | rerun `analyze.py` with the venv |
| `prep did not succeed` | PC unreachable from the phone | check `--pc` addresses match your LAN / Tailscale IPs |
| arms stop arriving, run continues | WiFi path died; Tailscale fallback in use | nothing to do — `uploader.sh` retries forever |

---

## Resuming a session that ran out of battery

`done.ledger` survives a reboot, so finished work is not repeated:

```bash
./deploy.sh --resume --out out/presets_stock
```

Resume keeps the on-device plan and ledger and only clears the stop marker.
It refuses to switch benchmark implementations underneath an existing dataset.
