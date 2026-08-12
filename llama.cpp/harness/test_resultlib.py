#!/usr/bin/env python3
"""
test_resultlib.py - tests for the result model and its pure functions.

Carried over from the retired test_harness.py. Those 62 tests covered both the
pure logic and the adb-driving orchestration; the orchestration is gone
(device/runner.sh owns it, and device/test_runner.sh tests it), so only the
pure surface survives here.

The functions themselves were verified equivalent to the originals against the
real historical dataset - 100 checks over 33 sweep arms, 8 telemetry files and
6 archived bench JSONs - before harness.py was deleted. These tests guard the
behaviour going forward.
"""

import io
import contextlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import resultlib
from resultlib import (Result, add_energy_metrics, control_verdict,
                       detect_suspend, dump, extract_bench_samples,
                       extract_bench_samples_ns, integrate_energy,
                       merge_results, parse_bench_text, parse_simpleperf,
                       result_is_valid, result_key, stats,
                       summarise_telemetry)


def bench_rows(samples_ts=None, avg_ts=None, samples_ns=None):
    row = {"model": "model.gguf", "n_threads": 6, "n_prompt": 0, "n_gen": 128}
    if samples_ts is not None:
        row["samples_ts"] = list(samples_ts)
    if avg_ts is not None:
        row["avg_ts"] = avg_ts
    if samples_ns is not None:
        row["samples_ns"] = list(samples_ns)
    return [row]


class TestStats(unittest.TestCase):
    """median + IQR, deliberately never mean/stddev."""

    def test_empty(self):
        self.assertEqual(stats([]), {})

    def test_single_value(self):
        s = stats([7.0])
        self.assertEqual((s["n"], s["median"], s["iqr"]), (1, 7.0, 0.0))

    def test_median_and_iqr(self):
        s = stats([1, 2, 3, 4, 5])
        self.assertEqual(s["median"], 3)
        self.assertEqual((s["min"], s["max"]), (1, 5))
        self.assertEqual(s["iqr"], s["q3"] - s["q1"])

    def test_median_is_not_the_mean(self):
        # the distributions are bimodal when threads migrate across clusters,
        # which is the whole reason this is a median
        s = stats([10, 10, 10, 10, 1000])
        self.assertEqual(s["median"], 10)


class TestExtraction(unittest.TestCase):

    def test_samples_ts_preferred_over_avg_ts(self):
        rows = bench_rows(samples_ts=[10.0, 11.0, 9.0], avg_ts=42.0)
        self.assertEqual(extract_bench_samples(rows), [10.0, 11.0, 9.0])

    def test_avg_fallback_when_no_samples(self):
        self.assertEqual(extract_bench_samples(bench_rows(avg_ts=3.5)), [3.5])

    def test_missing_avg_and_samples(self):
        self.assertEqual(extract_bench_samples([{}]), [])

    def test_samples_ns(self):
        rows = bench_rows(samples_ts=[1.0], samples_ns=[1000, 2000])
        self.assertEqual(extract_bench_samples_ns(rows), [1000, 2000])


class TestParseBenchText(unittest.TestCase):
    """A missing file and a malformed one have different causes."""

    def test_empty_is_missing(self):
        self.assertEqual(parse_bench_text(""), ([], "missing"))
        self.assertEqual(parse_bench_text("   \n"), ([], "missing"))

    def test_malformed_is_invalid(self):
        self.assertEqual(parse_bench_text("{not json"), ([], "invalid"))

    def test_valid_but_empty_is_no_samples(self):
        self.assertEqual(parse_bench_text("[]"), ([], "no_samples"))

    def test_valid_rows(self):
        rows, st = parse_bench_text(json.dumps(bench_rows(samples_ts=[10., 11.])))
        self.assertEqual(st, "ok")
        self.assertEqual(extract_bench_samples(rows), [10.0, 11.0])

    def test_json_embedded_in_noise_is_recovered(self):
        raw = "ggml_backend_load_best: warning\n" + \
              json.dumps(bench_rows(samples_ts=[5.0]))
        rows, st = parse_bench_text(raw)
        self.assertEqual(st, "ok")
        self.assertEqual(extract_bench_samples(rows), [5.0])


class TestSimpleperf(unittest.TestCase):

    REPORT = """Performance counter statistics:

# cpu            count  event_name               # count / runtime
  0        957,898,660  cpu-cycles:u             # 0.754181 GHz
  6    151,014,921,645  cpu-cycles:u             # 0.816262 GHz
"""

    def test_per_core_counts(self):
        c, mux = parse_simpleperf(self.REPORT)
        self.assertEqual(c["cpu0"]["cpu-cycles:u"], 957898660)
        self.assertEqual(c["cpu6"]["cpu-cycles:u"], 151014921645)
        self.assertFalse(mux)

    def test_multiplexing_is_flagged(self):
        # scaled counts are estimates; silently averaging them would be wrong
        _, mux = parse_simpleperf("  0  1,234  cpu-cycles:u  ( 43.21% )\n")
        self.assertTrue(mux)

    def test_garbage_is_ignored(self):
        c, _ = parse_simpleperf("not a report at all\n")
        self.assertEqual(c, {})


class TestEnergy(unittest.TestCase):

    def test_irregular_timestamps_trapezoid(self):
        # |I|*V with mA/mV scaling: 4.2 W, 12.6 W, 8.4 W at uneven spacing
        rows = [{"boottime_s": "0.0", "current_now": "1000", "voltage_now": "4200"},
                {"boottime_s": "0.5", "current_now": "3000", "voltage_now": "4200"},
                {"boottime_s": "2.0", "current_now": "2000", "voltage_now": "4200"}]
        out = integrate_energy(rows)
        self.assertEqual(out["method"], "trapezoidal_timestamped")
        # (4.2+12.6)/2*0.5 + (12.6+8.4)/2*1.5 = 4.2 + 15.75
        self.assertAlmostEqual(out["energy_j"], 19.95, places=1)
        self.assertEqual(out["gaps"], 0)

    def test_gaps_duplicates_and_bad_rows(self):
        rows = [{"boottime_s": "0.0", "current_now": "2000", "voltage_now": "4200"},
                {"boottime_s": "0.2", "current_now": "2000", "voltage_now": "4200"},
                {"boottime_s": "0.2", "current_now": "9999", "voltage_now": "4200"},
                {"boottime_s": "100.0", "current_now": "2000", "voltage_now": "4200"},
                {"boottime_s": "100.2", "current_now": "2000", "voltage_now": "4200"},
                {"boottime_s": "junk", "current_now": "2000", "voltage_now": "4200"}]
        out = integrate_energy(rows)
        self.assertEqual(out["samples_used"], 4)        # duplicate dropped
        self.assertEqual(out["samples_discarded"], 2)   # dup + unparseable
        self.assertEqual(out["gaps"], 1)                # never extrapolated
        self.assertGreater(out["gaps_s"], 99.0)
        self.assertAlmostEqual(out["energy_j"], 2 * (8.4 * 0.2), places=1)

    def test_too_few_samples(self):
        self.assertIsNone(integrate_energy([]))
        self.assertIsNone(integrate_energy(
            [{"boottime_s": "0", "current_now": "1", "voltage_now": "1"}]))

    def test_timestamped_preferred_for_efficiency(self):
        r = Result("c", "sweep", 6, "free", "tg", 0)
        r.extra["energy_j"] = 100.0
        r.extra["energy_j_timestamped"] = 90.0
        add_energy_metrics(r, 900, 0.0, 1.0)
        self.assertEqual(r.extra["tokens_per_joule"], 10.0)
        self.assertEqual(r.extra["energy_metric_used"], "energy_j_timestamped")

    def test_fallback_to_legacy_is_explicit(self):
        # never a silent metric swap
        r = Result("c", "sweep", 6, "free", "tg", 0)
        r.extra["energy_j"] = 100.0
        add_energy_metrics(r, 900, 0.0, 1.0)
        self.assertEqual(r.extra["tokens_per_joule"], 9.0)
        self.assertEqual(r.extra["energy_metric_used"], "energy_j")

    def test_scope_is_recorded(self):
        r = Result("c", "sweep", 6, "free", "tg", 0)
        r.extra["energy_j"] = 10.0
        add_energy_metrics(r, 100, 5.0, 9.0)
        self.assertEqual(r.extra["energy_scope"], "invocation_incl_setup")
        self.assertEqual(r.extra["energy_window"],
                         {"start_boottime": 5.0, "end_boottime": 9.0})


class TestSuspendDetection(unittest.TestCase):
    """Calibrated against real runs; see SUSPEND_GAP_S for the history."""

    def rows(self, times):
        return [{"boottime_s": str(t), "current_now": "300",
                 "voltage_now": "4000"} for t in times]

    def test_steady_cadence_is_clean(self):
        s, d = detect_suspend(self.rows([i * 0.2 for i in range(100)]))
        self.assertFalse(s)
        self.assertEqual(d["gaps"], 0)

    def test_real_freeze_detected(self):
        s, d = detect_suspend(self.rows([0.0, 0.2, 0.4, 185.0, 185.2]))
        self.assertTrue(s)
        self.assertAlmostEqual(d["max_gap_s"], 184.6, places=1)

    def test_eight_thread_sampler_starvation_is_not_a_suspend(self):
        # 22.30 s was measured on kai tg_t8_free.b2, which completed with
        # rc=0 and 20 valid samples. A 20 s threshold rejected it twice.
        s, _ = detect_suspend(self.rows([0.0, 0.2, 22.5, 22.7]))
        self.assertFalse(s)

    def test_threshold_is_the_calibrated_one(self):
        self.assertEqual(resultlib.SUSPEND_GAP_S, 60.0)
        # must stay above the worst observed starvation and below a real sleep
        self.assertGreater(resultlib.SUSPEND_GAP_S, 22.30)


class TestValidityAndIdentity(unittest.TestCase):

    def test_result_is_valid_variants(self):
        self.assertTrue(result_is_valid({"extra": {"valid": True}, "tps": [1.]}))
        self.assertFalse(result_is_valid({"extra": {"valid": False}, "tps": [1.]}))
        # legacy: no validity field -> completed iff it carries samples
        self.assertTrue(result_is_valid({"extra": {}, "tps": [1.0]}))
        self.assertFalse(result_is_valid({"extra": {}, "tps": []}))
        # pre-v5 uncertainty never counts as completed
        self.assertFalse(result_is_valid(
            {"extra": {"measurement_uncertain": True}, "tps": [1.0]}))

    def test_result_object_form(self):
        r = Result("c", "sweep", 4, "free", "tg", 0, tps=[1.0])
        r.extra["valid"] = True
        self.assertTrue(result_is_valid(r))

    def test_result_key_identity(self):
        r = Result("tg_t6_free", "sweep", 6, "free", "tg", 2)
        self.assertEqual(result_key(r),
                         ("sweep", "tg_t6_free", 6, "free", "tg", 2))

    def test_key_distinguishes_batches(self):
        a = Result("c", "sweep", 6, "free", "tg", 0)
        b = Result("c", "sweep", 6, "free", "tg", 1)
        self.assertNotEqual(result_key(a), result_key(b))


class TestMerge(unittest.TestCase):

    def row(self, batch, attempt, valid=True, reason=None, tps=(1.0,)):
        return {"mode": "sweep", "config": "c", "threads": 6, "mask": "free",
                "test": "tg", "rep_batch": batch, "tps": list(tps),
                "extra": {"attempt_id": attempt, "valid": valid,
                          "fail_reason": reason}}

    def test_replaces_rather_than_appends(self):
        merged = merge_results([self.row(0, "a"), self.row(1, "b")],
                               [self.row(1, "c")])
        self.assertEqual([r["rep_batch"] for r in merged], [0, 1])
        self.assertEqual(merged[1]["extra"]["attempt_id"], "c")

    def test_displaced_attempt_is_preserved(self):
        old = self.row(0, "first", valid=False, reason="benchmark_failed", tps=())
        merged = merge_results([old], [self.row(0, "second")])
        prev = merged[0]["extra"]["previous_attempts"]
        self.assertEqual(len(prev), 1)
        self.assertEqual(prev[0]["attempt_id"], "first")
        self.assertEqual(prev[0]["fail_reason"], "benchmark_failed")

    def test_remerging_the_same_attempt_is_idempotent(self):
        old = self.row(0, "old")
        new = self.row(0, "new")
        merged = merge_results([old], [new, new])
        self.assertEqual(len(merged[0]["extra"]["previous_attempts"]), 1)

    def test_deterministic_order(self):
        rows = [self.row(2, "c"), self.row(0, "a"), self.row(1, "b")]
        self.assertEqual([r["rep_batch"] for r in merge_results([], rows)],
                         [0, 1, 2])


class TestDumpAndTelemetry(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="resultlib_test_"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_dump_round_trip(self):
        r = Result("tg_t6_free", "sweep", 6, "free", "tg", 1,
                   tps=[10.0, 11.0, 12.0])
        dump([r], self.tmp)
        out = json.loads((self.tmp / "results.json").read_text())
        self.assertEqual(out[0]["tps"], [10.0, 11.0, 12.0])
        csv_txt = (self.tmp / "results.csv").read_text()
        self.assertIn("tps_median", csv_txt)

    def test_summarise_keeps_both_energy_estimates(self):
        csv = self.tmp / "telem.csv"
        csv.write_text("boottime_s,current_now,voltage_now\n"
                       "0.00,1000,4200\n1.00,1000,4200\n2.00,1000,4200\n")
        out = summarise_telemetry(str(csv), 0.0, 2.0)
        self.assertEqual(out["energy_j"], 8.4)              # legacy uniform-dt
        self.assertEqual(out["energy_j_timestamped"], 8.4)  # trapezoid
        self.assertEqual(out["energy_integration"]["samples_used"], 3)

    def test_summarise_missing_file(self):
        self.assertEqual(summarise_telemetry(str(self.tmp / "nope.csv"), 0, 1), {})

    def test_summarise_reports_suspend(self):
        csv = self.tmp / "t.csv"
        csv.write_text("boottime_s,current_now,voltage_now\n"
                       "0.00,1000,4200\n300.00,1000,4200\n")
        out = summarise_telemetry(str(csv), 0.0, 400.0)
        self.assertTrue(out["suspend_detected"])


class TestControlVerdict(unittest.TestCase):

    def verdict_text(self, delta_pct, blocks=4):
        rows = []
        for i in range(blocks):
            for arm in ("bare", "telemetry", "simpleperf"):
                med = 20.0 if arm == "bare" else 20.0 * (1 + delta_pct / 100)
                r = Result("tg_t6_free", f"control:{arm}", 6, "free", "tg", i,
                           tps=[med] * 4)
                r.extra["control_block"] = i
                r.extra["valid"] = True
                rows.append(r)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            control_verdict(rows)
        return buf.getvalue()

    def test_within_tolerance(self):
        self.assertIn("within configured tolerance", self.verdict_text(1.0))

    def test_above_tolerance(self):
        self.assertIn("above configured tolerance", self.verdict_text(2.0))

    def test_threshold_constant_is_explicit(self):
        # an engineering tolerance, not a significance test
        self.assertEqual(resultlib.CONTROL_NOISE_THRESHOLD_PCT, 1.5)

    def test_blocks_are_paired_not_pooled(self):
        rows = []
        for block in range(3):
            for arm, med in (("bare", 20.0), ("telemetry", 19.6),
                             ("simpleperf", 19.9)):
                r = Result("tg_t6_free", f"control:{arm}", 6, "free", "tg",
                           block, tps=[med] * 4)
                r.extra["control_block"] = block
                r.extra["valid"] = True
                rows.append(r)
        with contextlib.redirect_stdout(io.StringIO()):
            blocks = control_verdict(rows)
        self.assertEqual(len(blocks), 3)
        for _, arms in blocks.items():
            self.assertEqual(set(arms), {"bare", "telemetry", "simpleperf"})

    def test_invalid_arms_excluded(self):
        rows = []
        for arm in ("bare", "telemetry", "simpleperf"):
            r = Result("c", f"control:{arm}", 6, "free", "tg", 0, tps=[20.0])
            r.extra["control_block"] = 0
            r.extra["valid"] = (arm != "telemetry")
            rows.append(r)
        with contextlib.redirect_stdout(io.StringIO()):
            blocks = control_verdict(rows)
        self.assertNotIn("telemetry", blocks[("c", 0)])


class TestMatrix(unittest.TestCase):
    """The matrix is experiment identity; a silent change rewrites history."""

    def test_config_shape(self):
        for name, threads, mask, test in resultlib.CONFIGS:
            self.assertIsInstance(name, str)
            self.assertIn(test, ("tg", "pp"))
            self.assertTrue(mask is None or mask.startswith("0x"))
            self.assertGreater(threads, 0)

    def test_config_names_unique(self):
        names = [c[0] for c in resultlib.CONFIGS]
        self.assertEqual(len(names), len(set(names)))

    def test_event_sets_fit_the_counter_budget(self):
        # the device reports 7 PMU counters; every ":u" event consumes one
        self.assertLessEqual(len(resultlib.EVENTS_CORE), 7)
        self.assertLessEqual(len(resultlib.EVENTS_A55), 7)

    def test_schema_version(self):
        self.assertEqual(resultlib.RESULT_SCHEMA_VERSION, 5)


if __name__ == "__main__":
    unittest.main()
