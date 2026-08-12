#!/usr/bin/env python3
"""Hero figures for the README and the submission gallery.

    .venv/bin/python hero_figures.py

Separate from analyze.py on purpose. analyze.py draws every config on one axis
because it is a diagnostic - you want prefill and decode side by side when you
are reading a run. That is exactly wrong for a headline figure: prefill runs at
60-90 t/s and decode at 1.6-21, so on a shared axis the prefill bars set the
scale and the decode bars - which carry the entire finding - are squashed into
the bottom fifth. tg_default at 1.60 t/s becomes a sliver.

So these are decode-only, faceted by binary, one measure per figure. Two
measures of different scale get two charts, never two axes.

Form is EMPHASIS, not categorical: the default is the subject and the presets
are context, so the default gets the accent and everything else recedes to one
colour. Values are direct-labelled - four bars per panel is few enough that
labelling all of them beats making the reader trace a gridline.

Numbers come from results.json. Nothing here is hardcoded, so the figures
cannot drift away from the data the way a pasted number can.
"""

import json
import statistics as st
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "assets"

# Dark surface only. The submission gallery and GitHub both default dark for
# most viewers, and a chart designed for one mode beats one flipped into it.
SURFACE = "#1a1a19"
PAGE = "#0d0d0d"
INK = "#ffffff"
INK_2 = "#c3c2b7"
MUTED = "#898781"
GRID = "#2c2c2a"
BASE = "#383835"
# Validated as a pair against #1a1a19: CVD dE 19.2 (protan), normal 29.0, both >= 3:1.
ACCENT = "#e66767"   # the default - the thing that is wrong
CONTEXT = "#3987e5"  # the presets - context

RUNS = [("presets_stock", "stock llama.cpp"),
        ("presets_kai", "KleidiAI build")]


def load(run):
    """-> {config: (median t/s, J per 1k tokens)} for decode arms only."""
    d = json.loads((HERE / "out" / run / "results.json").read_text())
    out = {}
    for r in d:
        if r["test"] != "tg":
            continue
        e = r["extra"]
        out[r["config"]] = (st.median(r["tps"]), 1000.0 / e["tokens_per_joule"])
    return out


def bars(ax, labels, values, fmt, span, note):
    y = range(len(labels))
    for i, (lab, v) in enumerate(zip(labels, values)):
        colour = ACCENT if lab == "default" else CONTEXT
        # Square ends, deliberately. A rounded data-end is the nicer mark, but
        # FancyBboxPatch grows the box by the corner radius in BOTH axes, and
        # with a 4:1 value range on a shared scale the small bars ended up with
        # the rounding overshooting the bar itself - visible as stray vertical
        # strokes. A correct plain bar beats a pretty broken one.
        ax.barh(i, v, height=0.62, color=colour, zorder=3, linewidth=0)
        ax.text(v + span * 0.022, i, fmt(v), va="center", ha="left",
                color=INK if lab == "default" else INK_2,
                fontsize=10.5, fontweight="bold" if lab == "default" else "normal",
                zorder=4)
    ax.set_yticks(list(y))
    ax.set_yticklabels(labels, fontsize=10.5,
                       color=INK_2)
    for t, lab in zip(ax.get_yticklabels(), labels):
        if lab == "default":
            t.set_color(INK)
            t.set_fontweight("bold")
    ax.set_xlim(0, span)
    ax.set_ylim(-0.7, len(labels) - 0.3)
    ax.invert_yaxis()
    ax.set_xlabel(note, color=MUTED, fontsize=9.5, labelpad=8)
    ax.tick_params(axis="x", colors=MUTED, labelsize=9)
    ax.tick_params(axis="y", length=0)
    ax.grid(axis="x", color=GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right", "bottom"):
        ax.spines[s].set_visible(False)
    ax.spines["left"].set_color(BASE)
    ax.set_facecolor(SURFACE)


def figure(metric, title, sub, fmt, better_is_low, note, fname):
    fig, axes = plt.subplots(1, 2, figsize=(11.5, 3.9))
    fig.patch.set_facecolor(PAGE)

    panels = []
    for run, human in RUNS:
        data = load(run)
        rows = [("default" if c == "tg_default" else c.replace("tg_", ""), v[metric])
                for c, v in data.items()]
        # default first, then presets best-to-worst on this metric
        d = [r for r in rows if r[0] == "default"]
        p = sorted((r for r in rows if r[0] != "default"),
                   key=lambda r: r[1], reverse=not better_is_low)
        panels.append((human, d + p))

    # ONE scale across both facets. Independent axes on small multiples let a
    # reader compare bar lengths that are not comparable - here it would hide
    # that KleidiAI's presets are slower in absolute terms than stock's.
    span = max(v for _, rows in panels for _, v in rows) * 1.30

    for ax, (human, rows) in zip(axes, panels):
        labels = [r[0] for r in rows]
        values = [r[1] for r in rows]

        bars(ax, labels, values, fmt, span, note)

        dv = values[0]
        best = min(values[1:]) if better_is_low else max(values[1:])
        ratio = (dv / best) if better_is_low else (best / dv)
        ax.set_title(f"{human}\n{ratio:.1f}× {'more energy' if better_is_low else 'faster'}"
                     " than the default",
                     color=INK, fontsize=11.5, pad=12, loc="left", fontweight="bold")

    fig.suptitle(title, color=INK, fontsize=15, fontweight="bold",
                 x=0.045, y=0.985, ha="left")
    fig.text(0.045, 0.905, sub, color=MUTED, fontsize=10, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.90))
    OUT.mkdir(exist_ok=True)
    fig.savefig(OUT / fname, dpi=190, facecolor=PAGE)
    print("wrote", OUT / fname)


def main():
    figure(0,
           "llama.cpp's default thread count is its worst one",
           "Token generation, Qwen2 1B Q4_0, realme RMX5020 (6× Cortex-A55 + 2× Cortex-A75). "
           "Median of 5 reps. Higher is better.",
           lambda v: f"{v:.2f} t/s", False,
           "tokens / second", "hero_decode.png")

    figure(1,
           "The same default also burns the battery",
           "Energy per 1000 generated tokens, whole device, screen off and unplugged. "
           "±15–25%. Lower is better.",
           lambda v: f"{v:.0f} J", True,
           "joules per 1000 tokens", "hero_energy.png")


if __name__ == "__main__":
    main()
