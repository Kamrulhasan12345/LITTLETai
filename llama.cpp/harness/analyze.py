#!/usr/bin/env python3
"""
analyze.py - turn a harness run directory into tables and figures.

    python3 analyze.py out/run_20260804_120000

Produces, in the same directory:
    summary.md          median/IQR table, throttle flags, energy
    fig_throughput.png  throughput by config, median + IQR whiskers
    fig_timeline.png    throughput window vs frequency vs temperature
    fig_stalls.png      A55 interlock vs cache-miss stall decomposition
    fig_energy.png      tokens per joule
    derived.csv         per-config derived metrics incl. GB/s and IPC

Design notes:
  - medians and IQRs, never mean/stddev: the distributions are bimodal when
    threads migrate across clusters
  - any repetition whose window contains a frequency drop below 90% of the
    observed ceiling is flagged as throttled and reported separately
  - DRAM read bandwidth is derived from ll-cache-miss-rd * cache line size
"""

import csv
import json
import sys
from pathlib import Path

try:
    from resultlib import CONTROL_NOISE_THRESHOLD_PCT
except ImportError:   # pragma: no cover - standalone fallback
    CONTROL_NOISE_THRESHOLD_PCT = 1.5

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAVE_PLT = True
except ImportError:
    HAVE_PLT = False

LINE_BYTES = 64          # verify with coherency_line_size on device


def load(d, suffix=""):
    p = Path(d) / f"results{suffix}.json"
    return json.loads(p.read_text()) if p.exists() else []


def stats(vals):
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
    return {"n": n, "median": q(0.5), "q1": q(0.25), "q3": q(0.75),
            "iqr": q(0.75) - q(0.25), "min": s[0], "max": s[-1]}


def read_telemetry(path):
    if not path or not Path(path).exists():
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def throttled(rows, t0, t1):
    """True if any cluster dropped below 90% of its own observed ceiling."""
    if not rows:
        return False, {}
    cols = [k for k in rows[0] if k.endswith("_khz")]
    info, flag = {}, False
    for c in cols:
        v = []
        for r in rows:
            try:
                ts = float(r["boottime_s"])
            except (ValueError, TypeError, KeyError):
                continue
            if t0 <= ts <= t1 and r.get(c):
                try:
                    v.append(float(r[c]))
                except ValueError:
                    pass
        if v:
            ceil = max(v)
            low = sum(1 for x in v if x < 0.9 * ceil) / len(v)
            info[c] = {"ceiling_khz": ceil, "frac_below_90pct": round(low, 3)}
            if low > 0.15:
                flag = True
    return flag, info


def samples_of(r):
    """Per-repetition throughput samples for one result.

    schema v2 stores the raw llama-bench repetitions in
    ``extra["bench_samples_ts"]``; schema v1 only kept ``tps`` (which in the
    old harness was the aggregate ``avg_ts`` per row - a single value per
    batch). Old results therefore have ``n == number of json rows`` while
    new ones have ``n == reps`` and are nested inside batches.
    """
    extra = r.get("extra", {})
    return extra.get("bench_samples_ts") or r.get("tps", [])


def group(results):
    g = {}
    for r in results:
        # never pool failed/uncertain entries into the throughput figures
        extra = r.get("extra", {})
        if "valid" in extra and extra["valid"] is not True:
            continue
        if extra.get("measurement_uncertain"):
            continue
        g.setdefault(r["config"], []).extend(samples_of(r))
    return g


def batch_medians(results):
    """per-config list of (rep_batch, reaction median) pairs."""
    out = {}
    for r in results:
        if r.get("extra", {}).get("valid") is False:
            continue
        s = stats(samples_of(r))
        if s:
            out.setdefault(r["config"], []).append(
                (r["rep_batch"], s["median"]))
    return out


def derive_counters(cres):
    """Per-config PMU derivations: IPC, stall%, GB/s, per-cluster shares."""
    out = []
    for r in cres:
        c = r.get("extra", {}).get("counters", {})
        if not c:
            continue
        wall = r["extra"].get("wall_s", r["t_end"] - r["t_start"]) or 1
        row = {"config": r["config"], "mode": r["mode"],
               "threads": r["threads"], "mask": r["mask"],
               "multiplexed": r["extra"].get("multiplexed", False),
               "wall_s": round(wall, 2)}
        row["n_invocations"] = r["extra"].get("n_invocations", 1)
        tot_miss = 0
        a55 = {"cyc": 0, "ins": 0, "ilock": 0, "ldc": 0}
        a75 = {"cyc": 0, "ins": 0}
        for cpu, ev in c.items():
            idx = int(cpu.replace("cpu", ""))
            cyc = ev.get("cpu-cycles:u", 0)
            ins = ev.get("instructions:u", 0)
            miss = ev.get("raw-ll-cache-miss-rd:u", 0)
            tot_miss += miss
            if cyc:
                row[f"{cpu}_ipc"] = round(ins / cyc, 3)
            sb = ev.get("raw-stall-backend:u")
            if sb and cyc:
                row[f"{cpu}_stall_pct"] = round(100 * sb / cyc, 1)
            il = ev.get("raw-cortex-a55-stall-backend-ilock:u")
            ld = ev.get("raw-cortex-a55-stall-backend-ld-cache:u")
            if il and cyc:
                row[f"{cpu}_ilock_pct"] = round(100 * il / cyc, 1)
            if ld and cyc:
                row[f"{cpu}_ldcache_pct"] = round(100 * ld / cyc, 1)
            if idx <= 5:
                a55["cyc"] += cyc; a55["ins"] += ins
                a55["ilock"] += il or 0; a55["ldc"] += ld or 0
            else:
                a75["cyc"] += cyc; a75["ins"] += ins
            row[f"{cpu}_miss"] = miss
        if tot_miss:
            row["dram_read_gbps"] = round(tot_miss * LINE_BYTES / wall / 1e9, 3)
            big = sum(v.get("raw-ll-cache-miss-rd:u", 0)
                      for k, v in c.items()
                      if int(k.replace("cpu", "")) >= 6)
            row["a75_traffic_share_pct"] = round(100 * big / tot_miss, 1)
        if a55["cyc"]:
            row["a55_ipc"] = round(a55["ins"] / a55["cyc"], 3)
            if a55["ilock"]:
                row["a55_ilock_pct"] = round(100 * a55["ilock"] / a55["cyc"], 1)
                row["a55_ldcache_pct"] = round(100 * a55["ldc"] / a55["cyc"], 1)
                row["a55_ilock_over_ldcache"] = round(
                    a55["ilock"] / max(a55["ldc"], 1), 2)
        if a75["cyc"]:
            row["a75_ipc"] = round(a75["ins"] / a75["cyc"], 3)
        out.append(row)
    return out


def plot_throughput(g, outdir):
    if not HAVE_PLT or not g:
        return
    names = sorted(g, key=lambda k: -stats(g[k])["median"])
    med = [stats(g[n])["median"] for n in names]
    lo = [stats(g[n])["median"] - stats(g[n])["q1"] for n in names]
    hi = [stats(g[n])["q3"] - stats(g[n])["median"] for n in names]
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.bar(names, med, yerr=[lo, hi], capsize=4,
           color=["#4C72B0" if n.startswith("tg") else "#DD8452" for n in names])
    ax.set_ylabel("tokens/s (median, IQR whiskers)")
    ax.set_title("llama.cpp throughput by configuration")
    plt.xticks(rotation=40, ha="right")
    plt.tight_layout()
    plt.savefig(Path(outdir) / "fig_throughput.png", dpi=140)
    plt.close()


def plot_timeline(res, outdir):
    if not HAVE_PLT:
        return
    pick = None
    for r in res:
        if r.get("extra", {}).get("telemetry_csv"):
            pick = r
            break
    if not pick:
        return
    rows = read_telemetry(pick["extra"]["telemetry_csv"])
    if not rows:
        return
    ts = []
    for r in rows:
        try:
            ts.append(float(r["boottime_s"]))
        except (ValueError, TypeError, KeyError):
            ts.append(float("nan"))
    t0 = min(t for t in ts if t == t)
    x = [t - t0 for t in ts]
    fig, ax1 = plt.subplots(figsize=(11, 5))
    for k in rows[0]:
        if k.endswith("_khz"):
            y = [float(r[k]) / 1000 if r.get(k) else None for r in rows]
            ax1.plot(x, y, label=k.replace("_khz", ""), lw=1)
    ax1.set_xlabel("seconds since trace start")
    ax1.set_ylabel("CPU frequency (MHz)")
    ax1.legend(loc="upper left", fontsize=8)
    ax2 = ax1.twinx()
    for k in rows[0]:
        if k.endswith("_mC"):
            y = [float(r[k]) / 1000 if r.get(k) else None for r in rows]
            if any(v for v in y if v):
                ax2.plot(x, y, ls="--", lw=1, alpha=0.6)
    ax2.set_ylabel("temperature (C, dashed)")
    ax1.axvspan(pick["t_start"] - t0, pick["t_end"] - t0,
                color="grey", alpha=0.15, label="benchmark window")
    ax1.set_title(f"DVFS and thermal during {pick['config']}")
    plt.tight_layout()
    plt.savefig(Path(outdir) / "fig_timeline.png", dpi=140)
    plt.close()


def plot_stalls(derived, outdir):
    if not HAVE_PLT:
        return
    rows = [d for d in derived if "a55_ilock_pct" in d]
    if not rows:
        return
    names = [d["config"] for d in rows]
    il = [d["a55_ilock_pct"] for d in rows]
    ld = [d["a55_ldcache_pct"] for d in rows]
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.bar(names, il, label="interlock (in-order dependency)", color="#C44E52")
    ax.bar(names, ld, bottom=il, label="load / cache miss", color="#4C72B0")
    ax.set_ylabel("% of A55 cycles stalled")
    ax.set_title("Cortex-A55 backend stall decomposition")
    ax.legend()
    plt.xticks(rotation=35, ha="right")
    plt.tight_layout()
    plt.savefig(Path(outdir) / "fig_stalls.png", dpi=140)
    plt.close()


def plot_energy(res, outdir):
    if not HAVE_PLT:
        return
    d = {}
    for r in res:
        tpj = r.get("extra", {}).get("tokens_per_joule")
        if tpj:
            d.setdefault(r["config"], []).append(tpj)
    if not d:
        return
    names = sorted(d, key=lambda k: -stats(d[k])["median"])
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.bar(names, [stats(d[n])["median"] for n in names], color="#55A868")
    ax.set_ylabel("tokens / joule (device-level, median)")
    ax.set_title("Energy efficiency by configuration")
    plt.xticks(rotation=35, ha="right")
    plt.tight_layout()
    plt.savefig(Path(outdir) / "fig_energy.png", dpi=140)
    plt.close()


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: analyze.py <run_dir>")
    d = Path(sys.argv[1])
    sweep = load(d)
    counters = load(d, "_counters")
    control = load(d, "_control")
    man = {}
    if (d / "manifest.json").exists():
        man = json.loads((d / "manifest.json").read_text())

    L = ["# Benchmark summary", ""]
    if man:
        dev = man.get("device", {})
        bm = man.get("benchmark") or {}
        bm_name = bm.get("name")
        if bm_name:
            bm_line = (f"- benchmark: `{bm_name}` sha1: "
                       f"`{(bm.get('sha1') or ['?'])[0]}`")
        else:
            # legacy schema-3 manifest: only llama-bench existed
            bm_line = (f"- llama-bench sha1: "
                       f"`{(man.get('llama_bench_sha1') or ['?'])[0]}`")
        L += [f"- device: `{dev.get('model')}` / `{dev.get('soc')}` "
              f"Android {dev.get('android')}, kernel `{dev.get('kernel')}`",
              f"- battery at start: {dev.get('capacity')}% "
              f"({dev.get('battery_status')})",
              f"- airplane mode: {dev.get('airplane')}",
              f"- model sha1: `{(man.get('model_sha1') or ['?'])[0]}`",
              bm_line,
              f"- run: {man.get('utc')}", ""]

    g = group(sweep)
    if g:
        L += ["## Throughput (median, IQR)", "",
              "| config | threads | mask | test | n | median t/s | IQR | min | max | throttled |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        meta = {r["config"]: r for r in sweep}
        for name in sorted(g, key=lambda k: -stats(g[k])["median"]):
            s = stats(g[name])
            m = meta[name]
            th_flags = []
            for r in sweep:
                if r["config"] != name:
                    continue
                rows = read_telemetry(r.get("extra", {}).get("telemetry_csv"))
                f, _ = throttled(rows, r.get("t_start", 0.0),
                                 r.get("t_end", 0.0))
                th_flags.append(f)
            tf = f"{sum(th_flags)}/{len(th_flags)}" if th_flags else "-"
            L.append(f"| {name} | {m['threads']} | {m['mask']} | {m['test']} | "
                     f"{s['n']} | {s['median']:.2f} | {s['iqr']:.2f} | "
                     f"{s['min']:.2f} | {s['max']:.2f} | {tf} |")
        L.append("")
        L.append("> IQR, not stddev. A large IQR means the distribution is "
                 "bimodal (threads migrating across clusters) and the median "
                 "is the only honest summary.")
        L.append("")
        L.append("> Samples are per-repetition from llama-bench `samples_ts`, "
                 "nested inside `rep_batch` batches. Older results only have "
                 "the aggregate `avg_ts`; for them `n` = JSON rows, not reps.")
        L.append("")
        L.append("### Per-batch medians (t/s)")
        L.append("| config | per-batch medians | batches |")
        L.append("|---|---|---|")
        bm_all = batch_medians(sweep)
        for name in sorted(bm_all):
            meds = ", ".join(f"B{b}:{m:.2f}" for b, m in sorted(bm_all[name]))
            L.append(f"| {name} | {meds} | {len(bm_all[name])} |")
        L.append("")

    derived = derive_counters(counters)
    if derived:
        L += ["## PMU derivations", "",
              "Each row is one simpleperf invocation per (config, event "
              "set): `n_invocations = 1`. The PMU values are "
              "invocation-level measurements; they are not n=60 independent "
              "observations, so no variance is reported for them.", "",
              "| config | A55 IPC | A75 IPC | A55 ilock% | A55 ldcache% | "
              "ilock/ldcache | DRAM GB/s | A75 traffic share | multiplexed |",
              "|---|---|---|---|---|---|---|---|---|"]
        for r in derived:
            L.append(
                f"| {r['config']} | {r.get('a55_ipc','-')} | "
                f"{r.get('a75_ipc','-')} | {r.get('a55_ilock_pct','-')} | "
                f"{r.get('a55_ldcache_pct','-')} | "
                f"{r.get('a55_ilock_over_ldcache','-')} | "
                f"{r.get('dram_read_gbps','-')} | "
                f"{r.get('a75_traffic_share_pct','-')}% | "
                f"{'YES' if r.get('multiplexed') else 'no'} |")
        L += ["", "> `multiplexed = YES` means the kernel time-shared the PMU "
                  "counters and the counts are scaled estimates. Reduce the "
                  "event set below the hardware counter count and re-run.", ""]
        with open(d / "derived.csv", "w", newline="") as f:
            keys = sorted({k for r in derived for k in r})
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(derived)

    if control:
        L += ["## Harness overhead control", "",
              "| config | arm | n_blocks | median delta% vs bare | Q1 | Q3 | "
              "IQR |",
              "|---|---|---|---|---|---|---|"]
        # block-paired: one delta per block per config, computed from the
        # median of that block's own bare arm - never pooled across blocks,
        # so thermal drift between blocks cannot masquerade as overhead.
        blocks = {}
        for r in control:
            if r.get("extra", {}).get("valid") is False:
                continue
            arm = r["mode"].split(":")[1]
            key = (r["config"],
                   r.get("extra", {}).get("control_block", r["rep_batch"]))
            blocks.setdefault(key, {})[arm] = samples_of(r)
        for cfg in sorted({c for (c, _) in blocks}):
            for arm in ("telemetry", "simpleperf"):
                deltas = []
                for (c, b), arms in sorted(blocks.items()):
                    if c != cfg or "bare" not in arms or arm not in arms:
                        continue
                    bm = stats(arms["bare"]).get("median")
                    am = stats(arms[arm]).get("median")
                    if bm and am:
                        deltas.append(100 * (am - bm) / bm)
                s = stats(deltas)
                if not s:
                    continue
                within = abs(s["median"]) <= CONTROL_NOISE_THRESHOLD_PCT
                verdict = ("within configured tolerance" if within
                           else "above configured tolerance")
                L.append(f"| {cfg} | {arm} | {s['n']} | {s['median']:+.2f} | "
                         f"{s['q1']:+.2f} | {s['q3']:+.2f} | {s['iqr']:.2f} | "
                         f"-> {verdict}")
        L += ["", f"> Deltas are block-paired: within a block, the three "
                  f"arms share the same thermal window. The verdict compares "
                  f"the median block-paired delta against a configured "
                  f"engineering tolerance of +/- {CONTROL_NOISE_THRESHOLD_PCT}% "
                  "(`CONTROL_NOISE_THRESHOLD_PCT`) - descriptive, not a "
                  "significance test; a small number of blocks cannot "
                  "support a p-value claim.", ""]

    energy = [r["extra"]["tokens_per_joule"] for r in sweep
                if r.get("extra", {}).get("tokens_per_joule")]
    if energy:
        L += ["## Energy", "",
              "Device-wide tokens/joule (screen off, unplugged). Treat as "
              "+/-15-25%: whole-device draw, ~1s fuel-gauge granularity, "
              "no CPU rail isolation.", ""]
        metric_used = next((r.get("extra", {}).get("energy_metric_used")
                            for r in sweep
                            if r.get("extra", {}).get("energy_metric_used")),
                           "energy_j (historical)")
        L += [f"> `tokens_per_joule` here is derived from "
              f"`{metric_used}` (see `extra.energy_metric_used` in each "
              f"result).", ""]
        en_rows = [r for r in sweep
                   if r.get("extra", {}).get("tokens_per_joule")]
        if en_rows:
            w0 = min(r.get("extra", {}).get("energy_window", {}).get(
                "start_boottime", r["t_start"]) for r in en_rows)
            w1 = max(r.get("extra", {}).get("energy_window", {}).get(
                "end_boottime", r["t_end"]) for r in en_rows)
            scope = en_rows[0].get("extra", {}).get("energy_scope",
                                                    "invocation_incl_setup")
            tcount = en_rows[0].get("extra", {}).get("tokens_counted")
            L += [f"> Energy window is the benchmark *invocation* window on "
                  f"the device clock (boottime {w0:.0f}s..{w1:.0f}s), so it "
                  f"includes process setup/teardown"
                  + (f"; tokens counted per run: `{tcount}`"
                     if tcount else "")
                  + f". Scope: `{scope}`.", ""]

    (d / "summary.md").write_text("\n".join(L))
    plot_throughput(g, d)
    plot_timeline(sweep, d)
    plot_stalls(derived, d)
    plot_energy(sweep, d)
    print(f"wrote {d}/summary.md")
    if HAVE_PLT:
        print(f"wrote figures to {d}/")
    else:
        print("matplotlib not installed - tables only (pip install matplotlib)")


if __name__ == "__main__":
    main()
