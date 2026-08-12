#!/usr/bin/env python3
"""
resultlib.py - the benchmark result model, and every pure function that
operates on it. No adb, no device, no I/O beyond reading local files.

This is the correctness core of the harness, extracted from the original
harness.py so that it can be shared by the pieces that now own the work:

    plan.py     generates the run matrix (needs CONFIGS + the seeded shuffle)
    ingest.py   turns arms received from the phone into results.json
    analyze.py  turns results.json into tables and figures

The device-side runner (device/runner.sh) deliberately understands none of
this: it ships raw llama-bench JSON plus a key=value sidecar, and everything
here runs on the PC where it is testable.

Design rules preserved verbatim from the original harness:

  - median + IQR, never mean +/- stddev (the distributions are bimodal when
    threads migrate across clusters)
  - a result is valid only when it is explicitly marked so; an entry with no
    samples was never a usable measurement
  - energy provenance is always explicit - which estimate produced
    tokens_per_joule is recorded, never inferred
  - merging replaces by identity and preserves the displaced attempt, so a
    re-run is auditable rather than silent
"""

import csv
import json
import re
from dataclasses import dataclass, asdict, field
from pathlib import Path

# ------------------------------------------------------------------ matrix

# Cluster masks for this SoC: cpu0-5 = Cortex-A55, cpu6-7 = Cortex-A75.
MASK_ALL = "0xFF"
MASK_A55 = "0x3F"
MASK_A75 = "0xC0"
MASK_A55x2 = "0x03"
MASK_MIX = "0xC3"   # 2 big + 2 little

# (name, threads, cpu_mask, test)  test is "tg" (decode) or "pp" (prefill)
CONFIGS = [
    ("tg_t2_free",    2, None,       "tg"),
    ("tg_t4_free",    4, None,       "tg"),
    ("tg_t6_free",    6, None,       "tg"),
    ("tg_t8_free",    8, None,       "tg"),
    ("tg_t2_A75",     2, MASK_A75,   "tg"),
    ("tg_t6_A55",     6, MASK_A55,   "tg"),
    ("tg_t2_A55",     2, MASK_A55x2, "tg"),
    ("tg_t4_mix",     4, MASK_MIX,   "tg"),
    ("pp_t8_free",    8, None,       "pp"),
    ("pp_t6_A55",     6, MASK_A55,   "pp"),
    ("pp_t2_A75",     2, MASK_A75,   "pp"),
]

CONTROL_CONFIGS = [
    ("tg_t6_free", 6, None, "tg"),
    ("tg_t2_A75",  2, MASK_A75, "tg"),
]

N_GEN = 128       # tokens for tg
N_PROMPT = 512    # tokens for pp

BENCHMARKS = {
    "llama-bench": "llama-bench",
    "llama-bench-kai": "llama-bench-kai",
}
DEFAULT_BENCH = "llama-bench"

# PMU events for Pass B. Every ":u" event consumes one physical counter.
EVENTS_CORE = ["cpu-cycles:u", "instructions:u",
               "raw-stall-backend:u", "raw-ll-cache-miss-rd:u"]
EVENTS_A55 = ["cpu-cycles:u", "instructions:u",
              "raw-cortex-a55-stall-backend-ilock:u",
              "raw-cortex-a55-stall-backend-ld-cache:u"]

# Cooldown policy (enforced on-device; recorded here so the manifest and the
# runner cannot drift apart).
COOL_TARGET_MC = 42000     # milli-degC; start a run only below this
COOL_MAX_WAIT_S = 420      # give up waiting after this and record it
COOL_MIN_S = 45            # always wait at least this long between runs

SAMPLE_MS = 200

# Energy integration: gaps > this many seconds are NOT integrated across. At a
# 200 ms nominal cadence a hole this large is a real drop-out (or a device
# suspend), not jitter.
MAX_ENERGY_GAP_S = 30.0

# A sampler gap beyond this means the device froze - Android suspended under
# us, and any arm spanning it has corrupt wall-clock timing and energy.
#
# CALIBRATED TWICE, against real runs both times.
#
#   First pass: the historical Q4_K sweep showed a worst legitimate gap of
#   4.38 s, so 20 s looked like 4.5x margin.
#
#   That was wrong. With the faster Q4_0 model, 8-thread configs peg all eight
#   cores and starve the sampler's shell loop far harder. Measured across two
#   full 97-arm matrices:
#       kai     tg_t8_free.b2   22.30 s   <- rejected as a "suspend"
#       kai     tg_t8_free.b0   16.37 s
#       vanilla pp_t8_free.b0   19.46 s   <- accepted by 0.54 s
#   Every one of those is an 8-thread arm that completed with rc=0 and 20
#   valid samples. The 20 s threshold was discarding good measurements, and
#   vanilla escaped only by half a second.
#
# 60 s is ~2.7x the worst observed starvation gap, while a genuine Android
# deep-sleep is minutes. Energy remains separately protected: gaps beyond
# MAX_ENERGY_GAP_S (30 s) are excluded from the integral and counted, so a
# 30-60 s hole degrades energy without discarding throughput.
SUSPEND_GAP_S = 60.0

# Fuel gauge scaling, validated by energy_check.sh: current_now is mA,
# voltage_now is mV on this device.
ENERGY_I_SCALE = 1e-3      # raw -> amps
ENERGY_V_SCALE = 1e-3      # raw -> volts

# The A75 cluster on this device runs at ~850 MHz - its MINIMUM OPP - against
# a 2.0 GHz rating, under sustained full load. Confirmed by PMU (8.39e9 cycles
# over a 10 s pinned busy loop = 0.839 GHz, matching scaling_cur_freq's
# 0.850 GHz to 1.3%), so the sysfs node is honest. Cause is a vendor policy
# invisible to shell uid: not thermal (Thermal Status 0), not battery saver,
# not uclamp (max=1024), not cpuset placement. Treat absolute throughput as a
# lower bound at ~42% of rated clock; every comparison in the matrix is
# unaffected because all arms ran under the identical cap.
FREQ_CLAMP_NOTE = ("A75 pinned at ~850MHz min OPP (PMU-confirmed); "
                   "absolute t/s is a lower bound")

# Pass C verdict threshold: an engineering tolerance on the block-paired
# median delta, NOT a statistically proven bound.
CONTROL_NOISE_THRESHOLD_PCT = 1.5

# v5: the phone owns the loop. Results arrive as arms with a meta.kv sidecar;
# every arm carries boot_id and suspend_detected, and measurement_uncertain no
# longer exists (the process that ran the benchmark observed its exit code).
RESULT_SCHEMA_VERSION = 5


# ------------------------------------------------------------------- stats

def stats(vals):
    """median + IQR. Deliberately NOT mean/stddev."""
    if not vals:
        return {}
    s = sorted(vals)
    n = len(s)

    def q(p):
        if n == 1:
            return s[0]
        i = p * (n - 1)
        lo, hi = int(i), min(int(i) + 1, n - 1)
        return s[lo] + (s[hi] - s[lo]) * (i - lo)

    return {"n": n, "median": round(q(0.5), 3),
            "q1": round(q(0.25), 3), "q3": round(q(0.75), 3),
            "iqr": round(q(0.75) - q(0.25), 3),
            "min": round(s[0], 3), "max": round(s[-1], 3)}


# ------------------------------------------------------- benchmark parsing

def parse_bench_text(raw):
    """Parse llama-bench JSON text into ``(rows, status)``.

    status is one of:
      "missing"    - nothing to parse (file never written / empty)
      "invalid"    - text present but the JSON is malformed
      "no_samples" - JSON is valid but carries no usable rows
      "ok"         - at least one row parsed

    These must stay apart: a missing file and a malformed one have different
    causes and different failure reasons.

    (Was ``parse_bench_json(dev_path)``, which fetched the text over adb. The
    fetch is now the caller's problem - on-device the runner already has the
    bytes, and ingest reads them out of the received tar.)
    """
    if not raw or not raw.strip():
        return [], "missing"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\[.*\]", raw, re.S)
        if not m:
            return [], "invalid"
        try:
            data = json.loads(m.group(0))
        except json.JSONDecodeError:
            return [], "invalid"
    rows = data if isinstance(data, list) else [data]
    if not rows:
        return [], "no_samples"
    return rows, "ok"


def extract_bench_samples(rows):
    """Per-repetition throughput (tokens/s) from a llama-bench row list.

    Newer llama-bench emits ``samples_ts`` (one value per repetition); older
    builds only emit the aggregate ``avg_ts``. Prefer the samples; fall back
    to the aggregate so old results stay comparable, and let the caller mark
    the difference via ``samples_are_per_rep``.
    """
    samples = []
    for row in rows:
        samples_ts = row.get("samples_ts")
        if samples_ts:
            samples.extend(float(x) for x in samples_ts)
        elif row.get("avg_ts") is not None:
            samples.append(float(row["avg_ts"]))
    return samples


def extract_bench_samples_ns(rows):
    """Raw per-repetition total duration in ns (``samples_ns``)."""
    samples = []
    for row in rows:
        samples_ns = row.get("samples_ns")
        if samples_ns:
            samples.extend(int(x) for x in samples_ns)
    return samples


def parse_simpleperf(out):
    """Parse `simpleperf stat --per-core` output into {cpu: {event: count}}."""
    counters, multiplexed = {}, False
    if re.search(r"multiplex|not supported|scaled", out, re.I):
        multiplexed = bool(re.search(r"multiplex", out, re.I))
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+([\d,]+)\s+(\S+)", line)
        if not m:
            continue
        cpu, cnt, ev = m.group(1), m.group(2).replace(",", ""), m.group(3)
        if not cnt.isdigit():
            continue
        counters.setdefault(f"cpu{cpu}", {})[ev] = int(cnt)
        # simpleperf appends "(xx%)" when an event was time-multiplexed
        if re.search(r"\(\s*\d{1,2}(\.\d+)?%\s*\)", line):
            multiplexed = True
    return counters, multiplexed


# ------------------------------------------------------------------ energy

def integrate_energy(rows, max_gap_s=MAX_ENERGY_GAP_S):
    """Trapezoidal energy integral of |I|*V over *actual* sample timestamps.

    ``rows`` are the dicts of one telemetry CSV (each carrying
    ``boottime_s``, ``current_now``, ``voltage_now`` - see sampler.sh).
    Unlike the uniform-dt approximation this uses the real inter-sample
    spacing; it is a numerical estimate of E = int P(t) dt, not an exact
    measurement of it.

    Robustness (each is its own reason, and it shows in the metadata):
      - samples are sorted by timestamp
      - duplicate timestamps are dropped (counted in ``samples_discarded``)
      - zero/negative time deltas are ignored, never integrated
      - pairs spanning more than ``max_gap_s`` are NOT extrapolated across;
        each such hole is counted in ``gaps`` / ``gaps_s``
      - samples without a usable (current, voltage) pair are dropped and
        counted, never fabricated

    Returns ``None`` when fewer than two usable samples remain.
    """
    pts = []
    discarded = 0
    for r in rows:
        try:
            ts = float(r["boottime_s"])
            i = abs(float(r["current_now"])) * ENERGY_I_SCALE
            u = float(r["voltage_now"]) * ENERGY_V_SCALE
        except (KeyError, ValueError, TypeError):
            discarded += 1
            continue
        pts.append((ts, i * u))
    pts.sort()
    unique = []
    for ts, p in pts:
        if unique and unique[-1][0] == ts:
            discarded += 1        # duplicate timestamp: keep first sample
            continue
        unique.append((ts, p))
    if len(unique) < 2:
        return None
    joules, gaps_n, gaps_s = 0.0, 0, 0.0
    for (t0, p0), (t1, p1) in zip(unique, unique[1:]):
        dt = t1 - t0
        if dt <= 0:               # clock went backwards: not integrable
            continue
        if dt > max_gap_s:        # missing interval: don't extrapolate
            gaps_n += 1
            gaps_s += dt
            continue
        joules += 0.5 * (p0 + p1) * dt
    return {
        "method": "trapezoidal_timestamped",
        "start": unique[0][0],
        "end": unique[-1][0],
        "samples_used": len(unique),
        "samples_discarded": discarded,
        "gaps": gaps_n,
        "gaps_s": round(gaps_s, 2),
        "energy_j": round(joules, 2),
    }


def detect_suspend(rows, gap_s=SUSPEND_GAP_S):
    """Find Android suspends by looking for holes in the sampler cadence.

    sampler.sh writes a row every SAMPLE_MS (200 ms nominal) using
    CLOCK_BOOTTIME. The sampler is an ordinary userspace process, so when the
    device suspends it stops writing - a gap far beyond the cadence means the
    machine froze, which invalidates both wall-clock timing and the energy
    integral for any arm that spans it.

    Returns ``(suspended, detail)``. This is the only suspend signal the
    pipeline has; nothing else on an unrooted device reports it.
    """
    ts = []
    for r in rows:
        try:
            ts.append(float(r["boottime_s"]))
        except (KeyError, ValueError, TypeError):
            continue
    ts.sort()
    gaps = [(a, b - a) for a, b in zip(ts, ts[1:]) if b - a > gap_s]
    if not gaps:
        return False, {"max_gap_s": round(max(
            (b - a for a, b in zip(ts, ts[1:])), default=0.0), 3),
            "gaps": 0}
    return True, {
        "gaps": len(gaps),
        "total_gap_s": round(sum(g for _, g in gaps), 2),
        "max_gap_s": round(max(g for _, g in gaps), 2),
        "first_gap_at_boottime": round(gaps[0][0], 2),
    }


def summarise_telemetry(csv_path, t_start, t_end):
    """Slice the sampler CSV to [t_start,t_end] boottime and summarise.

    ``energy_j`` is the HISTORICAL metric (uniform spacing, dt = window/n).
    ``energy_j_timestamped`` integrates the same window over the actual
    sample timestamps. Both are stored so old numbers stay interpretable and
    new analysis can use the better-conditioned estimate.
    """
    if not csv_path or not Path(csv_path).exists():
        return {}
    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            try:
                ts = float(r["boottime_s"])
            except (KeyError, ValueError, TypeError):
                continue
            if t_start <= ts <= t_end:
                rows.append(r)
    if not rows:
        return {}

    def col(name, scale=1.0):
        vals = []
        for r in rows:
            v = r.get(name)
            if v not in (None, "", "-"):
                try:
                    vals.append(float(v) * scale)
                except ValueError:
                    pass
        return vals

    out = {"telemetry_samples": len(rows)}
    for k in rows[0].keys():
        if k.endswith("_khz"):
            v = col(k)
            if v:
                out[f"{k}_mean"] = round(sum(v) / len(v), 1)
                out[f"{k}_max"] = max(v)
        elif k.endswith("_mC"):
            v = col(k)
            if v:
                out[f"{k}_max"] = max(v)

    # legacy energy: uniform-dt approximation, kept for interpretability
    I = col("current_now", ENERGY_I_SCALE)
    V = col("voltage_now", ENERGY_V_SCALE)
    if I and V:
        n = min(len(I), len(V))
        dt = (t_end - t_start) / max(n, 1)
        joules = sum(abs(I[i]) * V[i] for i in range(n)) * dt
        out["energy_j"] = round(joules, 2)
        out["power_w_mean"] = round(joules / max(t_end - t_start, 1e-9), 3)
        integ = integrate_energy(rows)
        if integ:
            out["energy_j_timestamped"] = integ["energy_j"]
            out["energy_integration"] = {k: v for k, v in integ.items()
                                         if k != "energy_j"}

    suspended, detail = detect_suspend(rows)
    out["suspend_detected"] = suspended
    out["sampler_cadence"] = detail

    C = col("charge_counter")
    if len(C) >= 2:
        out["charge_delta_uah"] = C[0] - C[-1]
    return out


def add_energy_metrics(r, tokens_counted, t0, t1):
    """Attach energy provenance for one measured invocation.

    Scope is the WHOLE benchmark invocation incl. process setup/teardown, over
    the boottime window [t0, t1] - this is NOT pure inference energy, and no
    inference-only metric is claimed.

      - ``tokens_per_joule`` is derived from the preferred
        ``energy_j_timestamped`` estimate, falling back to the legacy
        ``energy_j`` when no timestamped estimate exists.
      - ``energy_metric_used`` records which estimate produced it, so the
        metric is never ambiguous. The fallback is explicit, never silent.
    """
    r.extra["tokens_counted"] = tokens_counted
    r.extra["energy_window"] = {"start_boottime": t0, "end_boottime": t1}
    r.extra["energy_scope"] = "invocation_incl_setup"
    ej_ts = r.extra.get("energy_j_timestamped")
    if ej_ts:
        r.extra["energy_metric_used"] = "energy_j_timestamped"
        r.extra["tokens_per_joule"] = round(tokens_counted / ej_ts, 3)
    elif r.extra.get("energy_j"):
        r.extra["energy_metric_used"] = "energy_j"
        r.extra["tokens_per_joule"] = round(
            tokens_counted / r.extra["energy_j"], 3)


# ------------------------------------------------------------------ result

@dataclass
class Result:
    config: str
    mode: str
    threads: int
    mask: str
    test: str
    rep_batch: int
    t_start: float = 0.0
    t_end: float = 0.0
    tps: list = field(default_factory=list)
    cool_wait_s: float = 0.0
    entry_temp_mC: float = 0.0
    cool_timeout: bool = False
    extra: dict = field(default_factory=dict)


def result_is_valid(r):
    """True iff a stored result is a completed, usable measurement.

    Results carry explicit validity in ``extra["valid"]``. Legacy entries
    (before that field existed) are treated as completed iff they hold
    throughput samples - an entry with no samples was never usable.

    ``measurement_uncertain`` is retained only to keep pre-v5 files readable:
    under the device-side runner the outcome is always known, because the
    process that launched the benchmark observed its exit code.
    """
    if hasattr(r, "extra"):
        extra = r.extra
    else:
        extra = r.get("extra") or {}
    if "valid" in extra:
        return extra["valid"] is True
    if extra.get("measurement_uncertain"):
        return False
    return bool(r.get("tps") if isinstance(r, dict) else r.tps)


def result_key(r):
    """Stable identity for one result within one outdir.

    (mode, config, threads, mask, test, rep_batch). rep_batch must be
    preserved when re-running a pass so resuming never renumbers batches.
    Works on both Result objects and (de)serialised dicts.
    """
    if hasattr(r, "mode"):
        r = asdict(r)
    return (r["mode"], r["config"], r["threads"], str(r["mask"]),
            r["test"], r["rep_batch"])


def attempt_record(r):
    """Compact provenance of one stored attempt, for the audit trail."""
    extra = r.get("extra", {}) if isinstance(r, dict) else r.extra
    return {
        "attempt_id": extra.get("attempt_id"),
        "valid": extra.get("valid", False),
        "fail_reason": extra.get("fail_reason"),
    }


def merge_results(existing, new):
    """Merge `new` into `existing`, dedup by result_key, deterministic order.

    Replaces rather than appends, so the final dataset holds each
    (config, rep_batch) exactly once. When a stored result is displaced by a
    different physical attempt, the old attempt's metadata is preserved in
    ``extra["previous_attempts"]`` instead of being silently dropped.
    Re-merging the same attempt is idempotent.
    """
    def norm(r):
        return asdict(r) if hasattr(r, "mode") else r

    by_key = {result_key(r): norm(r) for r in existing}
    for r in new:
        key = result_key(r)
        rep = norm(r)
        old = by_key.get(key)
        if old is not None and old.get("extra", {}).get("attempt_id") != \
                rep.get("extra", {}).get("attempt_id"):
            rec = attempt_record(old)
            history = rep.setdefault("extra", {}).setdefault(
                "previous_attempts", [])
            if rec not in history:
                history.append(rec)
        by_key[key] = rep
    merged = list(by_key.values())
    merged.sort(key=lambda r: (r["mode"], r["config"], r["rep_batch"]))
    return merged


def dump(results, outdir, suffix=""):
    """Write results{suffix}.json and a flattened results{suffix}.csv."""
    p = Path(outdir)
    rows_in = [asdict(r) if hasattr(r, "mode") else r for r in results]
    with open(p / f"results{suffix}.json", "w") as f:
        json.dump(rows_in, f, indent=2)
    flat = []
    for r in rows_in:
        row = {k: v for k, v in r.items() if k not in ("tps", "extra")}
        row.update({f"tps_{k}": v for k, v in stats(r.get("tps", [])).items()})
        for k, v in (r.get("extra") or {}).items():
            if isinstance(v, (int, float, str, bool)):
                row[k] = v
        flat.append(row)
    if flat:
        keys = sorted({k for row in flat for k in row})
        with open(p / f"results{suffix}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(flat)


# ----------------------------------------------------------- Pass C verdict

def control_verdict(results):
    """Block-paired overhead verdict per control config.

    Within each block the three arms are co-located in time, so
    (arm_median - bare_median) per block is the honest delta. Reports the
    median/Q1/Q3/IQR of those paired deltas.

    The verdict compares the median block-paired delta against
    CONTROL_NOISE_THRESHOLD_PCT. That is an engineering tolerance, not a
    statistical significance claim: with a small number of independent blocks
    no p-value is reported.
    """
    print("\n  --- control verdict (block-paired deltas) ---")
    print(f"  tolerance: +/- {CONTROL_NOISE_THRESHOLD_PCT}% "
          "(engineering threshold, not a significance test)")
    blocks = {}
    for r in results:
        if isinstance(r, dict):
            extra = r.get("extra", {})
            if "valid" in extra and extra["valid"] is not True:
                continue
            key = (r["config"], extra.get("control_block", r["rep_batch"]))
            arm = r["mode"].split(":")[1]
            blocks.setdefault(key, {})[arm] = r.get("tps", [])
        else:
            if r.extra.get("valid") is False:
                continue
            key = (r.config, r.extra.get("control_block", r.rep_batch))
            arm = r.mode.split(":")[1]
            blocks.setdefault(key, {})[arm] = r.tps
    for cfg in sorted({c for (c, _) in blocks}):
        deltas = {"telemetry": [], "simpleperf": []}
        for (c, b), arms in sorted(blocks.items()):
            if c != cfg or "bare" not in arms:
                continue
            bare_med = stats(arms["bare"]).get("median")
            if not bare_med:
                continue
            for arm in ("telemetry", "simpleperf"):
                if arm in arms and stats(arms[arm]).get("median"):
                    d = 100 * (stats(arms[arm])["median"] - bare_med) / bare_med
                    deltas[arm].append(d)
        for arm, ds in deltas.items():
            s = stats(ds)
            if not s:
                continue
            within = abs(s["median"]) <= CONTROL_NOISE_THRESHOLD_PCT
            verdict = ("within configured tolerance" if within
                       else "above configured tolerance")
            print(f"  {cfg:10s} {arm:11s} delta% med={s['median']:+.2f} "
                  f"Q1/Q3=({s['q1']:+.2f},{s['q3']:+.2f}) "
                  f"IQR={s['iqr']:.2f} n_blocks={s['n']} -> {verdict}")
    return blocks
