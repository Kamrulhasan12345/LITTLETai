#!/usr/bin/env python3
"""
test_plan.py - tests for the run-matrix generator.

The plan is the only place the randomised interleaving lives, and that
interleaving is the harness's main defence against confounding thermal drift
with a config. If it silently stops being random, or stops being
reproducible, every downstream number quietly loses its main validity
argument - so these tests are about the *properties*, not the literal bytes.
"""

import random
import tempfile
import unittest
from pathlib import Path

import plan
from resultlib import (CONFIGS, CONTROL_CONFIGS, EVENTS_CORE, EVENTS_A55,
                       N_GEN, N_PROMPT)


class TestCoverage(unittest.TestCase):
    """Every arm the old harness would have run must appear exactly once."""

    def test_sweep_covers_every_config_every_batch(self):
        rows = plan.plan_sweep(reps=20, batches=3, seed=1, trace_batches=1)
        self.assertEqual(len(rows), len(CONFIGS) * 3)
        seen = {(r["config"], r["rep_batch"]) for r in rows}
        self.assertEqual(
            seen, {(c[0], b) for c in CONFIGS for b in range(3)})

    def test_counters_is_decode_only_both_event_sets(self):
        rows = plan.plan_counters(reps=10, seed=1)
        tg = [c for c in CONFIGS if c[3] == "tg"]
        self.assertEqual(len(rows), len(tg) * 2)
        self.assertTrue(all(r["test"] == "tg" for r in rows))
        self.assertEqual({r["variant"] for r in rows}, {"core", "a55"})
        # prefill configs must never appear - counters are decode-only
        pp = {c[0] for c in CONFIGS if c[3] == "pp"}
        self.assertFalse({r["config"] for r in rows} & pp)

    def test_control_is_full_blocks(self):
        rows = plan.plan_control(reps=20, n_blocks=4, seed=1)
        self.assertEqual(len(rows), len(CONTROL_CONFIGS) * 3 * 4)
        for b in range(4):
            for cfg, _, _, _ in CONTROL_CONFIGS:
                arms = {r["variant"] for r in rows
                        if r["rep_batch"] == b and r["config"] == cfg}
                self.assertEqual(arms, {"bare", "telemetry", "simpleperf"})

    def test_arm_ids_unique(self):
        rows = plan.build("all", 20, 3, 8, 1234, 1)
        ids = [r["arm_id"] for r in rows]
        self.assertEqual(len(ids), len(set(ids)))

    def test_arm_ids_are_filesystem_and_wire_safe(self):
        # arm_id becomes a directory name AND crosses the network into a
        # filename; receiver.py refuses anything outside this alphabet.
        import re
        rows = plan.build("all", 20, 3, 8, 1234, 1)
        for r in rows:
            self.assertRegex(r["arm_id"], r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class TestReproducibility(unittest.TestCase):

    def test_same_seed_same_order(self):
        a = plan.build("all", 20, 3, 8, 1234, 1)
        b = plan.build("all", 20, 3, 8, 1234, 1)
        self.assertEqual([r["arm_id"] for r in a], [r["arm_id"] for r in b])

    def test_different_seed_different_order(self):
        a = plan.build("all", 20, 3, 8, 1234, 1)
        b = plan.build("all", 20, 3, 8, 4321, 1)
        self.assertNotEqual([r["arm_id"] for r in a],
                            [r["arm_id"] for r in b])

    def test_order_matches_original_harness_semantics(self):
        # The adb harness used one Random(seed) shuffled once per batch.
        # Reproduce that here so a given seed still means the same thing.
        rng = random.Random(99)
        expect = []
        for b in range(3):
            order = CONFIGS[:]
            rng.shuffle(order)
            expect += [f"sweep.{c[0]}.b{b}" for c in order]
        rows = plan.plan_sweep(reps=20, batches=3, seed=99, trace_batches=1)
        self.assertEqual([r["arm_id"] for r in rows], expect)

    def test_sweep_is_interleaved_not_blocked(self):
        # The whole point: a config must not run its batches back to back,
        # or thermal drift aligns with config identity.
        rows = plan.plan_sweep(reps=20, batches=3, seed=7, trace_batches=1)
        order = [r["config"] for r in rows]
        for cfg, _, _, _ in CONFIGS:
            idx = [i for i, c in enumerate(order) if c == cfg]
            self.assertEqual(len(idx), 3)
            # occurrences must be spread across the run, not adjacent
            self.assertGreater(idx[-1] - idx[0], len(CONFIGS),
                               f"{cfg} batches are clustered: {idx}")


class TestInstrumentationFlags(unittest.TestCase):
    """The runner is a dumb interpreter, so the flags must be exactly right."""

    def test_sweep_always_has_telemetry(self):
        # energy is derived from the sampler; a sweep arm without it would
        # silently produce no tokens_per_joule
        rows = plan.plan_sweep(reps=20, batches=3, seed=1, trace_batches=1)
        self.assertTrue(all(r["telemetry"] == 1 for r in rows))

    def test_trace_limited_to_requested_batches(self):
        rows = plan.plan_sweep(reps=20, batches=3, seed=1, trace_batches=1)
        self.assertTrue(all(r["trace"] == 1 for r in rows
                            if r["rep_batch"] == 0))
        self.assertTrue(all(r["trace"] == 0 for r in rows
                            if r["rep_batch"] > 0))

    def test_trace_can_be_disabled_entirely(self):
        rows = plan.plan_sweep(reps=20, batches=3, seed=1, trace_batches=0)
        self.assertTrue(all(r["trace"] == 0 for r in rows))

    def test_trace_can_cover_every_batch(self):
        rows = plan.plan_sweep(reps=20, batches=3, seed=1, trace_batches=3)
        self.assertTrue(all(r["trace"] == 1 for r in rows))

    def test_counters_never_traces_and_never_samples(self):
        # perfetto must not run alongside simpleperf: linux.perf is disabled
        # precisely so nothing contends for the PMU
        rows = plan.plan_counters(reps=10, seed=1)
        self.assertTrue(all(r["trace"] == 0 for r in rows))
        self.assertTrue(all(r["telemetry"] == 0 for r in rows))
        self.assertTrue(all(r["events"] != "-" for r in rows))

    def test_counters_event_sets_are_the_real_ones(self):
        rows = plan.plan_counters(reps=10, seed=1)
        for r in rows:
            want = EVENTS_CORE if r["variant"] == "core" else EVENTS_A55
            self.assertEqual(r["events"], ",".join(want))

    def test_control_arms_differ_only_in_instrumentation(self):
        rows = plan.plan_control(reps=20, n_blocks=1, seed=1)
        by_arm = {r["variant"]: r for r in rows
                  if r["config"] == CONTROL_CONFIGS[0][0]}
        bare, tel, sp = by_arm["bare"], by_arm["telemetry"], by_arm["simpleperf"]
        # bare is truly bare
        self.assertEqual((bare["telemetry"], bare["trace"], bare["events"]),
                         (0, 0, "-"))
        # telemetry arm carries sampler + perfetto, no counters
        self.assertEqual((tel["telemetry"], tel["trace"], tel["events"]),
                         (1, 1, "-"))
        # simpleperf arm carries counters, no sampler
        self.assertEqual((sp["telemetry"], sp["trace"]), (0, 0))
        self.assertEqual(sp["events"], ",".join(EVENTS_CORE))
        # and the workload itself is identical across the three
        for k in ("config", "threads", "mask", "test", "reps",
                  "n_prompt", "n_gen"):
            self.assertEqual(bare[k], tel[k], k)
            self.assertEqual(bare[k], sp[k], k)


class TestWorkloadShape(unittest.TestCase):

    def test_tg_and_pp_shapes(self):
        rows = plan.build("all", 20, 1, 1, 1, 1)
        for r in rows:
            if r["test"] == "tg":
                self.assertEqual((r["n_prompt"], r["n_gen"]), (0, N_GEN))
            else:
                self.assertEqual((r["n_prompt"], r["n_gen"]), (N_PROMPT, 0))

    def test_mask_free_is_spelled_free(self):
        rows = plan.build("sweep", 20, 1, 1, 1, 1)
        masks = {r["mask"] for r in rows}
        self.assertIn("free", masks)
        self.assertNotIn("None", masks)   # the classic str(None) bug

    def test_counters_use_fewer_reps(self):
        rows = plan.build("all", 20, 1, 1, 1, 1)
        sweep = next(r for r in rows if r["pass"] == "sweep")
        cnt = next(r for r in rows if r["pass"] == "counters")
        self.assertEqual(sweep["reps"], 20)
        self.assertEqual(cnt["reps"], 10)

    def test_counters_reps_floor(self):
        rows = plan.build("counters", 4, 1, 1, 1, 1)
        self.assertTrue(all(r["reps"] == 5 for r in rows))


class TestSerialisation(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="plan_test_"))
        import shutil
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_round_trip(self):
        rows = plan.build("all", 20, 3, 8, 1234, 1)
        p = self.tmp / "plan.tsv"
        plan.write_plan(rows, p)
        back = plan.read_plan(p)
        self.assertEqual(len(back), len(rows))
        for a, b in zip(rows, back):
            for c in plan.COLUMNS:
                self.assertEqual(str(a[c]), str(b[c]), f"{a['arm_id']}.{c}")

    def test_file_order_is_execution_order(self):
        rows = plan.build("all", 20, 2, 2, 5, 1)
        p = self.tmp / "plan.tsv"
        plan.write_plan(rows, p)
        self.assertEqual([r["arm_id"] for r in plan.read_plan(p)],
                         [r["arm_id"] for r in rows])

    def test_header_is_commented_so_sh_can_skip_it(self):
        plan.write_plan(plan.build("sweep", 2, 1, 1, 1, 1),
                        self.tmp / "plan.tsv")
        first = (self.tmp / "plan.tsv").read_text().splitlines()[0]
        self.assertTrue(first.startswith("#"))

    def test_no_field_contains_a_tab_or_newline(self):
        # the format is tab-separated and line-oriented; a stray tab in any
        # field would silently shift every column in the runner's read
        for r in plan.build("all", 20, 3, 8, 1234, 1):
            for c in plan.COLUMNS:
                self.assertNotIn("\t", str(r[c]))
                self.assertNotIn("\n", str(r[c]))

    def test_bad_column_count_is_rejected(self):
        p = self.tmp / "bad.tsv"
        p.write_text("#" + "\t".join(plan.COLUMNS) + "\nonly\ttwo\n")
        with self.assertRaises(ValueError):
            plan.read_plan(p)


class TestModes(unittest.TestCase):

    def test_mode_selects_passes(self):
        for mode, expect in (("sweep", {"sweep"}),
                             ("counters", {"counters"}),
                             ("control", {"control"}),
                             ("all", {"sweep", "counters", "control"})):
            rows = plan.build(mode, 20, 2, 2, 1, 1)
            self.assertEqual({r["pass"] for r in rows}, expect, mode)


if __name__ == "__main__":
    unittest.main()
