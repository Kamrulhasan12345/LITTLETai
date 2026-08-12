#!/usr/bin/env python3
"""
ingest.py - turn arms received from the phone into results{,_counters,_control}.json

    python3 ingest.py out/run_x            # inbox/ -> results*.json
    python3 ingest.py out/run_x --watch    # keep ingesting as arms arrive

This is where ALL interpretation happens. The device ships raw bytes and a
key=value sidecar; every decision about whether a measurement is usable is
made here, on the PC, under test.

Why the split matters: receiver.py acknowledges an arm the moment the bytes
are safely on disk, and only then does the phone delete its copy. If ingest
also owned that acknowledgement, a parsing bug could reject an arm that no
longer exists anywhere. Ingest can therefore be re-run, fixed, and re-run
again over the same inbox forever - it is a pure function of the inbox.

Validity ladder (first match wins), mirroring the original harness:

    cool_timeout           thermal_gate_timeout    never ran a hot bench
    timed_out              benchmark_timeout       killed at the wall clock
    rc != 0                benchmark_failed        definitely did not finish
    parse "missing"        bench_json_missing      exited 0, no JSON appeared
    parse "invalid"        bench_json_invalid      JSON unparseable
    no samples             bench_no_samples        parsed, nothing usable
    suspend_detected       suspend_during_measurement   device froze mid-arm
    otherwise              valid

There is deliberately no `measurement_uncertain`. That state existed only
because the laptop could not tell whether a benchmark it lost contact with
had completed. The device-side runner observes the exit code of the process
it started, so every outcome is now known.
"""

import argparse
import io
import json
import sys
import tarfile
import time
from pathlib import Path

import resultlib
from resultlib import (Result, add_energy_metrics, dump, extract_bench_samples,
                       extract_bench_samples_ns, merge_results,
                       parse_bench_text, parse_simpleperf, result_key, stats,
                       summarise_telemetry, N_GEN, N_PROMPT)

# Which results file each pass lands in. analyze.py reads exactly these.
SUFFIX = {"sweep": "", "counters": "_counters", "control": "_control"}

INT_KEYS = ("threads", "rep_batch", "reps", "n_prompt", "n_gen",
            "sampler_samples")
FLOAT_KEYS = ("t_start_boottime", "t_end_boottime", "cool_wait_s",
              "entry_temp_mC")
BOOL_KEYS = ("cool_timeout", "timed_out", "suspend_detected",
             "trace_captured", "trace_evicted", "telemetry")


def parse_kv(text):
    """Parse the device's meta.kv sidecar.

    Deliberately forgiving about unknown keys (the runner may add fields
    before this file learns about them) and strict about types it knows.
    """
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    for k in INT_KEYS:
        if k in out:
            try:
                out[k] = int(out[k])
            except ValueError:
                out[k] = 0
    for k in FLOAT_KEYS:
        if k in out:
            try:
                out[k] = float(out[k])
            except ValueError:
                out[k] = 0.0
    for k in BOOL_KEYS:
        if k in out:
            out[k] = str(out[k]).strip().lower() in ("1", "true", "yes")
    return out


def read_arm(tar_path):
    """Unpack one received arm into {member_name: bytes}.

    Members are read by basename so the device is free to tar with or
    without a leading directory component.
    """
    files = {}
    with tarfile.open(tar_path, "r:*") as tf:
        for m in tf.getmembers():
            if not m.isfile():
                continue
            name = Path(m.name).name
            f = tf.extractfile(m)
            if f is not None:
                files[name] = f.read()
    return files


def mode_of(meta):
    """Result.mode, in the exact shape analyze.py already understands."""
    p = meta.get("pass", "sweep")
    variant = meta.get("variant", "-")
    if p == "sweep" or variant in ("-", "", None):
        return p
    return f"{p}:{variant}"


def classify(meta, parse_status, tps):
    """Return (valid, fail_reason). First failure in the ladder wins."""
    if meta.get("cool_timeout"):
        return False, "thermal_gate_timeout"
    if meta.get("timed_out"):
        return False, "benchmark_timeout"
    if str(meta.get("rc", "0")) not in ("0", ""):
        return False, "benchmark_failed"
    if parse_status == "missing":
        return False, "bench_json_missing"
    if parse_status == "invalid":
        return False, "bench_json_invalid"
    if not tps:
        return False, "bench_no_samples"
    if meta.get("suspend_detected"):
        # The device froze mid-arm: wall-clock timing and the energy integral
        # are both corrupt. Throughput might look plausible, which is exactly
        # why this must not be quietly accepted.
        return False, "suspend_during_measurement"
    return True, None


def build_result(files, telemetry_path=None):
    """Turn one received arm into a Result. Pure: no I/O beyond the CSV."""
    meta = parse_kv(files.get("meta.kv", b"").decode("utf-8", "replace"))
    if not meta.get("arm_id"):
        raise ValueError("arm has no meta.kv/arm_id")

    rows, parse_status = parse_bench_text(
        files.get("bench.json", b"").decode("utf-8", "replace"))
    tps = extract_bench_samples(rows)
    tps_ns = extract_bench_samples_ns(rows)

    t0 = meta.get("t_start_boottime", 0.0)
    t1 = meta.get("t_end_boottime", 0.0)

    r = Result(
        config=meta.get("config", "?"),
        mode=mode_of(meta),
        threads=meta.get("threads", 0),
        mask=meta.get("mask", "free"),
        test=meta.get("test", "tg"),
        rep_batch=meta.get("rep_batch", 0),
        t_start=t0, t_end=t1, tps=tps,
        cool_wait_s=meta.get("cool_wait_s", 0.0),
        entry_temp_mC=meta.get("entry_temp_mC", 0.0),
        cool_timeout=bool(meta.get("cool_timeout")),
    )

    e = r.extra
    e["arm_id"] = meta["arm_id"]
    e["attempt_id"] = meta.get("attempt_id")
    e["boot_id"] = meta.get("boot_id")
    e["benchmark"] = meta.get("bench", resultlib.DEFAULT_BENCH)
    e["wall_s"] = round(t1 - t0, 2)
    e["bench_samples_ts"] = tps
    e["bench_samples_ns"] = tps_ns
    e["samples_are_per_rep"] = bool(tps)
    e["schema_version"] = resultlib.RESULT_SCHEMA_VERSION
    if meta.get("variant", "-") != "-":
        e["variant"] = meta["variant"]
    if meta.get("events", "-") != "-":
        e["events"] = meta["events"].split(",")
    if meta.get("pass") == "control":
        e["control_block"] = meta.get("rep_batch", 0)
    for k in ("battery_status_start", "battery_capacity_start",
              "battery_status_end", "trace_captured", "trace_evicted",
              "sampler_samples", "rc"):
        if k in meta:
            e[k] = meta[k]

    # simpleperf report, when this arm carried counters
    if "perf.txt" in files:
        raw = files["perf.txt"].decode("utf-8", "replace")
        counters, multiplexed = parse_simpleperf(raw)
        e["counters"] = counters
        e["multiplexed"] = multiplexed
        e["n_invocations"] = 1
        e["raw"] = raw[-4000:]

    # telemetry: energy, frequency/thermal summaries, suspend detection
    if telemetry_path is not None:
        e.update(summarise_telemetry(str(telemetry_path), t0, t1))
        # The telemetry CSV is AUTHORITATIVE when present, overriding the
        # device's own flag rather than OR-ing with it. The device decides
        # once, with whatever threshold it shipped with; ingest can be fixed
        # and re-run over the same inbox forever. OR-ing meant a device-side
        # false positive was permanent - it discarded a good arm twice and
        # could only have been undone by re-running the benchmark.
        e["suspend_detected"] = bool(e.get("suspend_detected"))
        e["suspend_detected_by_device"] = bool(meta.get("suspend_detected"))
        meta["suspend_detected"] = e["suspend_detected"]

    valid, reason = classify(meta, parse_status, tps)
    e["valid"] = valid
    e["device_online"] = True     # the device ran this; it was, by definition
    if reason:
        e["fail_reason"] = reason

    if valid:
        ntok = r.tps and meta.get("reps", 0) * (
            N_GEN if r.test == "tg" else N_PROMPT)
        if ntok:
            add_energy_metrics(r, ntok, t0, t1)
        # Charging invalidates ENERGY only - the throughput measurement is
        # still perfectly good, so drop the derived metric rather than the arm.
        if "Charging" in str(meta.get("battery_status_start", "")) or \
                "Charging" in str(meta.get("battery_status_end", "")):
            e.pop("tokens_per_joule", None)
            e["energy_invalid_reason"] = "battery_charging_during_arm"
    return r


def ingest_dir(outdir, keep_telemetry=True):
    """Ingest every arm in <outdir>/inbox into results*.json. Idempotent."""
    outdir = Path(outdir)
    inbox = outdir / "inbox"
    if not inbox.is_dir():
        sys.exit(f"no inbox at {inbox}")

    tel_dir = outdir / "telemetry"
    tel_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = outdir / "bench_json"
    raw_dir.mkdir(parents=True, exist_ok=True)

    # Traced arms arrive as TWO tars: "<arm>.tar" with the measurement, and
    # "<arm>.trace.tar" with the perfetto capture. The trace tar carries a
    # copy of the same meta.kv - same arm_id - but no bench.json, so treating
    # it as an arm produced a bogus `bench_json_missing` that then REPLACED
    # the real result via merge_results (identical result_key, and ".trace"
    # sorts after ".tar"). Collect traces first, separately, and attach them.
    traces = {}
    for tar_path in sorted(inbox.glob("*.trace.tar")):
        base = tar_path.name[:-len(".trace.tar")]
        try:
            tf = read_arm(tar_path)
        except (tarfile.TarError, OSError) as e:
            skipped_early = (tar_path.name, f"unreadable trace tar: {e}")
            continue
        blob = next((v for k, v in tf.items()
                     if k.endswith(".perfetto-trace")), None)
        if blob is None:
            continue
        td = outdir / "traces"
        td.mkdir(parents=True, exist_ok=True)
        tp = td / f"{base}.perfetto-trace"
        tp.write_bytes(blob)
        traces[base] = str(tp)

    by_pass = {}
    skipped = []
    for tar_path in sorted(inbox.glob("*.tar")):
        if tar_path.name.endswith(".trace.tar"):
            continue        # already handled above
        if tar_path.name in ("manifest.tar", "preflight.tar"):
            # preflight ships before the matrix so a gate failure reaches the
            # operator without adb. It is apparatus provenance, not a
            # measurement, so it is kept beside the results rather than
            # parsed as an arm.
            try:
                files = read_arm(tar_path)
                if "meta.kv" in files:
                    (outdir / f"{tar_path.stem}.kv").write_bytes(files["meta.kv"])
            except (tarfile.TarError, OSError):
                pass
            continue
        try:
            files = read_arm(tar_path)
        except (tarfile.TarError, OSError) as e:
            skipped.append((tar_path.name, f"unreadable tar: {e}"))
            continue
        try:
            meta_txt = files.get("meta.kv", b"").decode("utf-8", "replace")
            arm_id = parse_kv(meta_txt).get("arm_id") or tar_path.stem

            # Land the telemetry CSV on disk: summarise_telemetry reads a
            # path, and analyze.py's timeline figure wants it later.
            tel_path = None
            if "telemetry.csv" in files and keep_telemetry:
                tel_path = tel_dir / f"{arm_id}.csv"
                tel_path.write_bytes(files["telemetry.csv"])

            r = build_result(files, tel_path)
            if tel_path is not None:
                r.extra["telemetry_csv"] = str(tel_path)

            # Preserve the untouched benchmark output: everything in
            # results*.json is derived, this is the source of truth.
            if "bench.json" in files:
                p = raw_dir / f"bench_{arm_id}.json"
                p.write_bytes(files["bench.json"])
                r.extra["bench_json"] = str(p)
            if arm_id in traces:
                r.extra["perfetto_trace"] = traces[arm_id]
        except (ValueError, KeyError) as e:
            skipped.append((tar_path.name, str(e)))
            continue

        pass_name = parse_kv(meta_txt).get("pass", "sweep")
        by_pass.setdefault(pass_name, []).append(r)

    # Merge into whatever is already there. merge_results dedups on
    # result_key and records a displaced attempt in previous_attempts, so
    # re-ingesting the same inbox is a no-op and a re-run replaces cleanly.
    totals = {}
    for pass_name, results in by_pass.items():
        suffix = SUFFIX.get(pass_name, f"_{pass_name}")
        p = outdir / f"results{suffix}.json"
        existing = json.loads(p.read_text()) if p.exists() else []
        merged = merge_results(existing, results)
        dump(merged, outdir, suffix=suffix)
        totals[pass_name] = (len(merged),
                             sum(1 for r in merged
                                 if r.get("extra", {}).get("valid")))
    return totals, skipped


def report(totals, skipped):
    if not totals and not skipped:
        print("inbox is empty - nothing to ingest")
        return
    for pass_name, (n, valid) in sorted(totals.items()):
        suffix = SUFFIX.get(pass_name, f"_{pass_name}")
        print(f"  results{suffix}.json: {n} arms, {valid} valid, "
              f"{n - valid} failed")
    for name, why in skipped:
        print(f"  !! skipped {name}: {why}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", help="run directory containing inbox/")
    ap.add_argument("--watch", action="store_true",
                    help="re-ingest every --interval seconds as arms arrive")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--no-telemetry", action="store_true",
                    help="skip writing telemetry CSVs (faster re-ingest)")
    args = ap.parse_args()

    while True:
        totals, skipped = ingest_dir(args.outdir,
                                     keep_telemetry=not args.no_telemetry)
        print(f"[{time.strftime('%H:%M:%S')}] ingested {args.outdir}")
        report(totals, skipped)
        if not args.watch:
            break
        time.sleep(args.interval)

    print(f"next: python3 analyze.py {args.outdir}")


if __name__ == "__main__":
    sys.exit(main())
