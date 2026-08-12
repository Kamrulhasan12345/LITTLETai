#!/usr/bin/env python3
"""
test_ingest.py - tests for turning received arms into results.

These are the tests that decide whether a measurement is trusted. The device
now runs unattended for many hours, so nothing here may depend on a human
noticing something looked wrong: every way an arm can be bad must produce an
explicit, named failure rather than a plausible-looking number.
"""

import io
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path

import ingest
import resultlib


def make_tar(path, files):
    """Write {name: bytes|str} as a tar, the way the device ships an arm."""
    with tarfile.open(path, "w") as tf:
        for name, data in files.items():
            if isinstance(data, str):
                data = data.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))


def bench_json(samples=(10.0, 11.0, 12.0)):
    return json.dumps([{
        "model": "model.gguf", "n_threads": 6, "n_prompt": 0, "n_gen": 128,
        "samples_ts": list(samples),
        "samples_ns": [int(1e9 / s) for s in samples],
        "avg_ts": sum(samples) / len(samples),
    }])


def meta_kv(**over):
    m = {
        "arm_id": "sweep.tg_t6_free.b0", "pass": "sweep",
        "config": "tg_t6_free", "threads": 6, "mask": "free", "test": "tg",
        "rep_batch": 0, "reps": 20, "bench": "llama-bench",
        "attempt_id": "aaaa1111", "boot_id": "boot-abc",
        "t_start_boottime": 1000.0, "t_end_boottime": 1300.0,
        "rc": 0, "timed_out": 0, "cool_wait_s": 60.0,
        "entry_temp_mC": 38000, "cool_timeout": 0,
        "battery_status_start": "Discharging", "battery_capacity_start": 92,
        "battery_status_end": "Discharging", "suspend_detected": 0,
        "sampler_samples": 1500, "trace_captured": 0, "trace_evicted": 0,
        "variant": "-", "events": "-",
    }
    m.update(over)
    return "\n".join(f"{k}={v}" for k, v in m.items()) + "\n"


def telemetry_csv(start=1000.0, n=200, step=0.2, gap_at=None, gap=0.0):
    lines = ["boottime_s,policy0_khz,policy6_khz,current_now,voltage_now,"
             "charge_counter"]
    t = start
    for i in range(n):
        lines.append(f"{t:.2f},850000,850000,300,4000,{3000000 - i}")
        t += step
        if gap_at is not None and i == gap_at:
            t += gap
    return "\n".join(lines) + "\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ingest_test_"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.inbox = self.tmp / "inbox"
        self.inbox.mkdir()

    def arm(self, name="sweep.tg_t6_free.b0", **files):
        payload = {"meta.kv": files.pop("meta", meta_kv(arm_id=name)),
                   "bench.json": files.pop("bench", bench_json())}
        payload.update(files)
        payload = {k: v for k, v in payload.items() if v is not None}
        make_tar(self.inbox / f"{name}.tar", payload)

    def run_ingest(self):
        return ingest.ingest_dir(self.tmp)

    def results(self, suffix=""):
        p = self.tmp / f"results{suffix}.json"
        return json.loads(p.read_text()) if p.exists() else []


class TestHappyPath(Base):

    def test_valid_arm_becomes_valid_result(self):
        self.arm(telemetry_csv=telemetry_csv())
        self.run_ingest()
        out = self.results()
        self.assertEqual(len(out), 1)
        r = out[0]
        self.assertTrue(r["extra"]["valid"])
        self.assertEqual(r["config"], "tg_t6_free")
        self.assertEqual(r["mode"], "sweep")
        self.assertEqual(r["tps"], [10.0, 11.0, 12.0])
        self.assertTrue(r["extra"]["samples_are_per_rep"])
        self.assertNotIn("fail_reason", r["extra"])

    def test_raw_bench_json_is_preserved_untouched(self):
        raw = bench_json()
        self.arm(bench=raw)
        self.run_ingest()
        p = self.tmp / "bench_json" / "bench_sweep.tg_t6_free.b0.json"
        self.assertTrue(p.exists())
        self.assertEqual(p.read_text(), raw)

    def test_energy_derived_when_telemetry_present(self):
        self.arm(**{"telemetry.csv": telemetry_csv()})
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertIn("tokens_per_joule", e)
        self.assertEqual(e["tokens_counted"], 20 * resultlib.N_GEN)
        self.assertEqual(e["energy_scope"], "invocation_incl_setup")
        self.assertIn(e["energy_metric_used"],
                      ("energy_j_timestamped", "energy_j"))

    def test_no_energy_claimed_without_telemetry(self):
        self.arm()      # no telemetry.csv at all
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertTrue(e["valid"])
        self.assertNotIn("tokens_per_joule", e)

    def test_modes_route_to_the_right_results_file(self):
        self.arm("sweep.tg_t6_free.b0")
        self.arm("counters.tg_t6_free.core",
                 meta=meta_kv(arm_id="counters.tg_t6_free.core",
                              **{"pass": "counters", "variant": "core",
                                 "events": ",".join(resultlib.EVENTS_CORE)}),
                 **{"perf.txt": " 0  12,345 cpu-cycles:u\n"
                                " 0  6,000 instructions:u\n"})
        self.arm("control.tg_t2_A75.bare.b0",
                 meta=meta_kv(arm_id="control.tg_t2_A75.bare.b0",
                              config="tg_t2_A75",
                              **{"pass": "control", "variant": "bare"}))
        self.run_ingest()
        self.assertEqual(len(self.results()), 1)
        self.assertEqual(len(self.results("_counters")), 1)
        self.assertEqual(len(self.results("_control")), 1)
        self.assertEqual(self.results("_counters")[0]["mode"],
                         "counters:core")
        self.assertEqual(self.results("_control")[0]["mode"], "control:bare")

    def test_counters_parsed_into_result(self):
        self.arm("counters.tg_t6_free.core",
                 meta=meta_kv(arm_id="counters.tg_t6_free.core",
                              **{"pass": "counters", "variant": "core"}),
                 **{"perf.txt": " 0  12,345 cpu-cycles:u\n"
                                " 6  99,999 cpu-cycles:u\n"})
        self.run_ingest()
        e = self.results("_counters")[0]["extra"]
        self.assertEqual(e["counters"]["cpu0"]["cpu-cycles:u"], 12345)
        self.assertEqual(e["counters"]["cpu6"]["cpu-cycles:u"], 99999)
        self.assertFalse(e["multiplexed"])
        self.assertEqual(e["n_invocations"], 1)

    def test_control_block_recorded_for_pass_c_pairing(self):
        # control_verdict pairs arms within a block; without this key the
        # verdict silently falls back to rep_batch
        self.arm("control.tg_t6_free.bare.b3",
                 meta=meta_kv(arm_id="control.tg_t6_free.bare.b3",
                              rep_batch=3,
                              **{"pass": "control", "variant": "bare"}))
        self.run_ingest()
        self.assertEqual(self.results("_control")[0]["extra"]["control_block"],
                         3)


class TestFailureClassification(Base):
    """Every bad arm must name its own failure. No silent plausible numbers."""

    def assert_fails_with(self, reason, **arm_kw):
        self.arm(**arm_kw)
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertFalse(e["valid"])
        self.assertEqual(e["fail_reason"], reason)

    def test_thermal_gate_timeout(self):
        self.assert_fails_with("thermal_gate_timeout",
                               meta=meta_kv(cool_timeout=1), bench="")

    def test_benchmark_timeout(self):
        self.assert_fails_with("benchmark_timeout",
                               meta=meta_kv(timed_out=1, rc=124), bench="")

    def test_benchmark_failed_nonzero_rc(self):
        self.assert_fails_with("benchmark_failed",
                               meta=meta_kv(rc=1), bench="")

    def test_bench_json_missing(self):
        self.assert_fails_with("bench_json_missing", bench="")

    def test_bench_json_invalid(self):
        self.assert_fails_with("bench_json_invalid", bench="{not json")

    def test_bench_no_samples(self):
        self.assert_fails_with("bench_no_samples", bench="[]")

    def test_suspend_flagged_by_device(self):
        self.assert_fails_with("suspend_during_measurement",
                               meta=meta_kv(suspend_detected=1))

    def test_suspend_detected_from_telemetry_even_if_device_missed_it(self):
        # belt and braces: the device says fine, but the sampler cadence
        # shows a 200 s hole. Trust the data.
        self.arm(meta=meta_kv(suspend_detected=0),
                 **{"telemetry.csv": telemetry_csv(n=100, gap_at=50,
                                                   gap=200.0)})
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertTrue(e["suspend_detected"])
        self.assertFalse(e["valid"])
        self.assertEqual(e["fail_reason"], "suspend_during_measurement")

    def test_ordinary_sampler_jitter_is_not_a_suspend(self):
        # 4.4 s was the worst legitimate gap measured across the historical
        # sweep; it must not invalidate a good arm
        self.arm(**{"telemetry.csv": telemetry_csv(n=100, gap_at=50,
                                                   gap=4.4)})
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertFalse(e["suspend_detected"])
        self.assertTrue(e["valid"])

    def test_failed_arm_keeps_its_attempt_id(self):
        self.arm(meta=meta_kv(rc=1, attempt_id="dead0001"), bench="")
        self.run_ingest()
        self.assertEqual(self.results()[0]["extra"]["attempt_id"], "dead0001")

    def test_no_uncertain_state_exists_anymore(self):
        self.arm(meta=meta_kv(rc=1), bench="")
        self.run_ingest()
        e = self.results()[0]["extra"]
        self.assertNotIn("measurement_uncertain", e)
        self.assertTrue(e["device_online"])


class TestEnergyValidity(Base):

    def test_charging_kills_energy_but_keeps_throughput(self):
        self.arm(meta=meta_kv(battery_status_start="Charging"),
                 **{"telemetry.csv": telemetry_csv()})
        self.run_ingest()
        r = self.results()[0]
        self.assertTrue(r["extra"]["valid"])           # throughput is fine
        self.assertEqual(r["tps"], [10.0, 11.0, 12.0])
        self.assertNotIn("tokens_per_joule", r["extra"])
        self.assertEqual(r["extra"]["energy_invalid_reason"],
                         "battery_charging_during_arm")

    def test_charging_detected_at_end_of_arm_too(self):
        self.arm(meta=meta_kv(battery_status_end="Charging"),
                 **{"telemetry.csv": telemetry_csv()})
        self.run_ingest()
        self.assertNotIn("tokens_per_joule", self.results()[0]["extra"])


class TestIdempotenceAndMerge(Base):

    def test_reingest_is_a_noop(self):
        self.arm(**{"telemetry.csv": telemetry_csv()})
        self.run_ingest()
        first = self.results()
        self.run_ingest()
        self.run_ingest()
        self.assertEqual(self.results(), first)
        self.assertEqual(len(self.results()), 1)

    def test_rerun_replaces_and_records_previous_attempt(self):
        # a failed arm, then the device re-queues it and it succeeds
        self.arm(meta=meta_kv(rc=1, attempt_id="first111"), bench="")
        self.run_ingest()
        self.assertFalse(self.results()[0]["extra"]["valid"])

        self.arm(meta=meta_kv(attempt_id="second22"))
        self.run_ingest()
        out = self.results()
        self.assertEqual(len(out), 1)                  # replaced, not appended
        self.assertTrue(out[0]["extra"]["valid"])
        self.assertEqual(out[0]["extra"]["attempt_id"], "second22")
        prev = out[0]["extra"]["previous_attempts"]
        self.assertEqual(len(prev), 1)
        self.assertEqual(prev[0]["attempt_id"], "first111")
        self.assertEqual(prev[0]["fail_reason"], "benchmark_failed")

    def test_distinct_batches_do_not_collide(self):
        for b in range(3):
            self.arm(f"sweep.tg_t6_free.b{b}",
                     meta=meta_kv(arm_id=f"sweep.tg_t6_free.b{b}",
                                  rep_batch=b))
        self.run_ingest()
        self.assertEqual(sorted(r["rep_batch"] for r in self.results()),
                         [0, 1, 2])

    def test_boot_id_is_recorded(self):
        # boottime restarts at a reboot, so windows are only comparable
        # within one boot_id. Ingest must carry it through.
        self.arm(meta=meta_kv(boot_id="boot-xyz"))
        self.run_ingest()
        self.assertEqual(self.results()[0]["extra"]["boot_id"], "boot-xyz")


class TestTracedArms(Base):
    """A traced arm ships two tars; the trace must not eat the measurement."""

    def trace_arm(self, name):
        # exactly what runner.sh commits: same meta.kv, no bench.json
        make_tar(self.inbox / f"{name}.trace.tar", {
            "meta.kv": meta_kv(arm_id=name),
            "trace.perfetto-trace": b"PERFETTO-BYTES",
        })

    def test_trace_tar_does_not_overwrite_the_measurement(self):
        # Regression: ".trace.tar" sorts after ".tar", carries the same
        # arm_id and therefore the same result_key, and has no bench.json -
        # so it used to replace a good arm with bench_json_missing. That
        # silently failed every traced arm in the matrix.
        self.arm("sweep.tg_t6_free.b0")
        self.trace_arm("sweep.tg_t6_free.b0")
        self.run_ingest()
        out = self.results()
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0]["extra"]["valid"])
        self.assertEqual(out[0]["tps"], [10.0, 11.0, 12.0])
        self.assertNotIn("fail_reason", out[0]["extra"])

    def test_trace_is_attached_to_its_arm(self):
        self.arm("sweep.tg_t6_free.b0")
        self.trace_arm("sweep.tg_t6_free.b0")
        self.run_ingest()
        tp = self.results()[0]["extra"].get("perfetto_trace")
        self.assertTrue(tp, "trace was not attached to the result")
        self.assertEqual(Path(tp).read_bytes(), b"PERFETTO-BYTES")

    def test_trace_without_its_measurement_creates_no_phantom_arm(self):
        self.trace_arm("sweep.tg_t6_free.b0")
        self.run_ingest()
        self.assertEqual(self.results(), [])

    def test_untraced_arm_still_has_no_trace(self):
        self.arm("sweep.tg_t2_free.b1",
                 meta=meta_kv(arm_id="sweep.tg_t2_free.b1"))
        self.run_ingest()
        self.assertIsNone(self.results()[0]["extra"].get("perfetto_trace"))


class TestRobustness(Base):

    def test_corrupt_tar_is_skipped_not_fatal(self):
        (self.inbox / "broken.tar").write_bytes(b"this is not a tar at all")
        self.arm()                       # one good arm alongside it
        totals, skipped = self.run_ingest()
        self.assertEqual(len(self.results()), 1)
        self.assertEqual(len(skipped), 1)
        self.assertIn("broken.tar", skipped[0][0])

    def test_arm_without_meta_is_skipped_not_fatal(self):
        make_tar(self.inbox / "nometa.tar", {"bench.json": bench_json()})
        self.arm()
        totals, skipped = self.run_ingest()
        self.assertEqual(len(self.results()), 1)
        self.assertEqual(len(skipped), 1)

    def test_unknown_meta_keys_are_tolerated(self):
        self.arm(meta=meta_kv(some_future_field="hello"))
        self.run_ingest()
        self.assertTrue(self.results()[0]["extra"]["valid"])

    def test_malformed_meta_values_do_not_crash(self):
        self.arm(meta=meta_kv(threads="notanumber",
                              t_start_boottime="nope"))
        self.run_ingest()
        self.assertEqual(len(self.results()), 1)

    def test_empty_inbox(self):
        totals, skipped = self.run_ingest()
        self.assertEqual(totals, {})
        self.assertEqual(skipped, [])


class TestAnalyzeCompatibility(Base):
    """ingest's output must feed analyze.py unchanged."""

    def test_analyze_runs_on_ingested_results(self):
        import analyze
        for b in range(2):
            self.arm(f"sweep.tg_t6_free.b{b}",
                     meta=meta_kv(arm_id=f"sweep.tg_t6_free.b{b}",
                                  rep_batch=b),
                     **{"telemetry.csv": telemetry_csv()})
        self.arm("control.tg_t6_free.bare.b0",
                 meta=meta_kv(arm_id="control.tg_t6_free.bare.b0",
                              **{"pass": "control", "variant": "bare"}))
        self.run_ingest()
        analyze.sys.argv = ["analyze.py", str(self.tmp)]
        analyze.main()
        md = (self.tmp / "summary.md").read_text()
        self.assertIn("## Throughput", md)
        self.assertIn("tg_t6_free", md)
        self.assertIn("Per-batch medians", md)


if __name__ == "__main__":
    unittest.main()
