#!/usr/bin/env python3
"""
plan.py - generate the run matrix the phone will execute.

    python3 plan.py --mode all --reps 20 --batches 3 --seed 1234 -o plan.tsv

The plan is generated HERE, on the PC, for one reason: the randomised
interleaving is the harness's main defence against confounding thermal drift
with a specific config, and a seeded RNG is only reproducible if it runs
somewhere testable. toybox `sh` has no seeded shuffle worth trusting.

The output is deliberately *self-describing*: every column the runner needs is
in the row, so device/runner.sh never has to know what a "pass" is, which
configs are prefill, or which events belong to which event set. It reads flags
and executes them. All benchmark semantics stay on this side.

Column reference
----------------
arm_id      unique, stable, filesystem-safe; the outbox directory name
pass        sweep | counters | control          (provenance only)
config      matrix entry name, e.g. tg_t6_free
threads     -t
mask        cpu mask for -C, or "free" for no mask
test        tg | pp                             (provenance only)
reps        -r
rep_batch   batch index; also the control block index
n_prompt    -p
n_gen       -n
telemetry   1 = run sampler.sh during this arm
trace       1 = run perfetto during this arm
events      comma-joined PMU events for simpleperf, or "-" for none
variant     event-set name, control arm name, or "-"

Ordering within the file IS the execution order. The runner walks it top to
bottom and never reorders.
"""

import argparse
import random
import sys
from pathlib import Path

from resultlib import (CONFIGS, CONTROL_CONFIGS, EVENTS_CORE, EVENTS_A55,
                       N_GEN, N_PROMPT)

COLUMNS = ["arm_id", "pass", "config", "threads", "mask", "test", "reps",
           "rep_batch", "n_prompt", "n_gen", "telemetry", "trace", "events",
           "variant"]

CONTROL_ARMS = ["bare", "telemetry", "simpleperf"]


def shape(test):
    """(-p, -n) for a test kind. tg = decode, pp = prefill."""
    return (0, N_GEN) if test == "tg" else (N_PROMPT, 0)


def row(arm_id, pass_, config, threads, mask, test, reps, rep_batch,
        telemetry, trace, events, variant):
    n_prompt, n_gen = shape(test)
    return {
        "arm_id": arm_id,
        "pass": pass_,
        "config": config,
        "threads": threads,
        "mask": mask or "free",
        "test": test,
        "reps": reps,
        "rep_batch": rep_batch,
        "n_prompt": n_prompt,
        "n_gen": n_gen,
        "telemetry": int(telemetry),
        "trace": int(trace),
        "events": ",".join(events) if events else "-",
        "variant": variant or "-",
    }


def usable_configs(skip_masked):
    """The matrix, optionally minus the configs that depend on cpu masking.

    Masking works via taskset (runner MASK_MODE=taskset, the default), so
    these configs are normally kept. The flag exists because llama-bench's
    own -C is silently ignored on Android before llama.cpp PR #26838
    (2026-08-10): measured here, `-C 0x03 --cpu-strict 1` put 99.5% of cycles
    on the big cores, indistinguishable from no mask, while `taskset 03` put
    0.1% there. If masking ever fails preflight again, --no-masked drops
    these four and keeps the seven that do not depend on it.
    """
    if not skip_masked:
        return CONFIGS
    return [c for c in CONFIGS if c[2] is None]


def plan_sweep(reps, batches, seed, trace_batches, skip_masked=False):
    """Pass A. Interleaved + randomised config order across batches.

    Mirrors the original run_sweep: ONE rng, shuffled once per batch, so the
    order for a given seed is identical to what the adb-driven harness
    produced. Never blocked by config - thermal drift must not be able to
    align with a single config.
    """
    rng = random.Random(seed)
    rows = []
    base = usable_configs(skip_masked)
    for b in range(batches):
        order = base[:]
        rng.shuffle(order)
        for (name, th, mask, test) in order:
            rows.append(row(
                arm_id=f"sweep.{name}.b{b}", pass_="sweep", config=name,
                threads=th, mask=mask, test=test, reps=reps, rep_batch=b,
                # Telemetry is the measurement (energy comes from it), so it
                # runs on every arm. The perfetto trace is diagnostic and
                # ~1500x larger, so by default only the first batch carries
                # one - see --trace-batches.
                telemetry=True, trace=(b < trace_batches),
                events=None, variant=None))
    return rows


def plan_counters(reps, seed, skip_masked=False):
    """Pass B. simpleperf, decode configs only, both event sets interleaved.

    Observation unit: ONE (config, event-set) row = ONE simpleperf
    invocation. llama-bench's internal -r reps happen inside it, so this is
    n=1 PMU observation per row, not n=reps. No variance is manufactured.

    Counters and perfetto never run together: perfetto's linux.perf source is
    disabled precisely so it cannot contend for the PMU, and telemetry is off
    here so the counted workload is as clean as possible.
    """
    rng = random.Random(seed)
    units = []
    for setname, events in (("core", EVENTS_CORE), ("a55", EVENTS_A55)):
        for (name, th, mask, test) in usable_configs(skip_masked):
            if test != "tg":
                continue          # counters on decode only, keeps it short
            units.append((setname, events, name, th, mask, test))
    rng.shuffle(units)
    return [row(arm_id=f"counters.{name}.{setname}", pass_="counters",
                config=name, threads=th, mask=mask, test=test, reps=reps,
                rep_batch=0, telemetry=False, trace=False,
                events=events, variant=setname)
            for setname, events, name, th, mask, test in units]


def plan_control(reps, n_blocks, seed):
    """Pass C. Block design: every (config, arm) pair once per block.

    Arm order is shuffled per config so ordering effects cannot accumulate.
    The verdict is computed block-paired, which is why all three arms of a
    block must sit together in one thermal window - do not reorder these
    across blocks.

    The arms differ in exactly what instrumentation runs, which is what the
    pass measures:
        bare       nothing
        telemetry  sampler + perfetto
        simpleperf simpleperf, no sampler
    """
    rng = random.Random(seed)
    rows = []
    for i in range(n_blocks):
        for (name, th, mask, test) in CONTROL_CONFIGS:
            arms = CONTROL_ARMS[:]
            rng.shuffle(arms)
            for arm in arms:
                rows.append(row(
                    arm_id=f"control.{name}.{arm}.b{i}", pass_="control",
                    config=name, threads=th, mask=mask, test=test,
                    reps=reps, rep_batch=i,
                    telemetry=(arm == "telemetry"),
                    trace=(arm == "telemetry"),
                    events=EVENTS_CORE if arm == "simpleperf" else None,
                    variant=arm))
    return rows


def build(mode, reps, batches, control_n, seed, trace_batches,
          skip_masked=False):
    """Build the plan. `mode` may be a comma-separated list of passes.

    Combining passes matters for battery-limited sessions: a full matrix does
    not fit in one charge, so the run is split across sessions, and each
    session must be a single unattended command rather than one the operator
    has to be present to advance.
    """
    mode = set(m.strip() for m in str(mode).split(",") if m.strip())
    if "all" in mode:
        mode |= {"sweep", "counters", "control"}
    rows = []
    if mode & {"all", "sweep"}:
        rows += plan_sweep(reps, batches, seed, trace_batches, skip_masked)
    if mode & {"all", "counters"}:
        # counters use fewer reps: one simpleperf invocation is already long,
        # and it yields a single PMU observation regardless of -r.
        rows += plan_counters(max(reps // 2, 5), seed, skip_masked)
    if mode & {"all", "control"}:
        rows += plan_control(reps, control_n, seed)
    return rows


def write_plan(rows, path):
    lines = ["#" + "\t".join(COLUMNS)]
    for r in rows:
        lines.append("\t".join(str(r[c]) for c in COLUMNS))
    Path(path).write_text("\n".join(lines) + "\n")
    return len(rows)


def read_plan(path):
    """Parse a plan.tsv back into dicts. Used by ingest and the tests."""
    rows = []
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        vals = line.split("\t")
        if len(vals) != len(COLUMNS):
            raise ValueError(
                f"plan row has {len(vals)} columns, expected {len(COLUMNS)}: "
                f"{line!r}")
        r = dict(zip(COLUMNS, vals))
        for k in ("threads", "reps", "rep_batch", "n_prompt", "n_gen",
                  "telemetry", "trace"):
            r[k] = int(r[k])
        rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", default="all",
                    help="all | sweep | counters | control, or a comma-"
                         "separated combination such as 'counters,control' "
                         "so one session can cover several passes unattended")
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--batches", type=int, default=3)
    ap.add_argument("--control-n", type=int, default=8)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--trace-batches", type=int, default=1,
                    help="how many sweep batches carry a perfetto trace "
                         "(default 1; traces are ~1500x larger than the "
                         "measurement itself). Use --trace-batches 0 to "
                         "disable tracing, or a number >= --batches to trace "
                         "every arm.")
    ap.add_argument("--no-masked", action="store_true",
                    help="drop the configs that rely on -C cpu masking. On "
                         "this device the mask is ignored (99.5%% of a 0x03 "
                         "run landed on cpu6-7), so those configs duplicate "
                         "their unmasked twins instead of comparing clusters.")
    ap.add_argument("-o", "--out", default="plan.tsv")
    args = ap.parse_args()

    rows = build(args.mode, args.reps, args.batches, args.control_n,
                 args.seed, args.trace_batches, args.no_masked)
    n = write_plan(rows, args.out)

    traced = sum(r["trace"] for r in rows)
    by_pass = {}
    for r in rows:
        by_pass[r["pass"]] = by_pass.get(r["pass"], 0) + 1
    print(f"wrote {args.out}: {n} arms  "
          f"({', '.join(f'{k}={v}' for k, v in by_pass.items())})")
    print(f"  traced arms: {traced}  (~{traced * 16} MB worst case at the "
          f"16 MB ring cap)")
    print(f"  seed {args.seed} - re-running this command reproduces the "
          f"exact order")


if __name__ == "__main__":
    sys.exit(main())
