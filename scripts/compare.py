#!/usr/bin/env python3
"""compare.py — diff two run directories and emit a Markdown report.

Usage:
    python3 scripts/compare.py \
        --a results/orin/2026-04-23T17-00-00Z \
        --b results/s100/2026-04-23T17-00-00Z \
        --out reports/orin-vs-s100.md \
        [--charts]   # also write PNG charts alongside the Markdown

Behaviour:
- Loads every *.json (except env.json) from each run dir.
- Joins by `benchmark` id, then by metric name.
- For each numeric metric (uses p50, falling back to avg/p95/p99/max), reports
  A, B, absolute delta, percent delta, and optional perf-per-W columns.
- When a benchmark result contains a `power_w` metric, adds "A perf/W" and
  "B perf/W" columns (metric_primary / power_w_avg) for higher-is-better metrics.
- Reads env.json from both sides and emits a fairness statement table.
- Higher-is-better vs lower-is-better is inferred from the metric name
  (latency/jitter/temp/power/error -> lower; everything else -> higher).

Charts (--charts):
- Bar chart: normalised B/A ratio per metric (>1 = B better for higher-is-better).
- Radar chart: same data on a polar axis, one spoke per metric.
  Both PNG files are written next to --out.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

LOWER_BETTER_HINTS = ("latency", "jitter", "delay", "wakeup", "temp", "power_w", "error", "loss", "miss")


def is_lower_better(metric_name: str) -> bool:
    name = metric_name.lower()
    return any(h in name for h in LOWER_BETTER_HINTS)


def load_run(run_dir: Path) -> dict[str, Any]:
    if not run_dir.is_dir():
        sys.exit(f"not a directory: {run_dir}")
    benchmarks: dict[str, dict[str, Any]] = {}
    for jf in sorted(run_dir.glob("*.json")):
        if jf.name == "env.json":
            continue
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"WARN: skip {jf} (invalid JSON: {e})", file=sys.stderr)
            continue
        bid = doc.get("benchmark")
        if not bid:
            print(f"WARN: skip {jf} (no 'benchmark' field)", file=sys.stderr)
            continue
        benchmarks[bid] = doc
    env_path = run_dir / "env.json"
    env = json.loads(env_path.read_text(encoding="utf-8")) if env_path.exists() else {}
    return {"path": run_dir, "benchmarks": benchmarks, "env": env}


def primary_value(metric: dict[str, Any]) -> float | None:
    for key in ("p50", "avg", "p95", "p99", "max"):
        v = metric.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def fmt(v: float | None) -> str:
    if v is None:
        return "—"
    if abs(v) >= 1000:
        return f"{v:,.1f}"
    if abs(v) >= 1:
        return f"{v:.3f}"
    return f"{v:.4g}"


def _first_line(s: str | None) -> str | None:
    if not s:
        return None
    lines = s.splitlines()
    return lines[0] if lines else None


def render_fairness(env_a: dict, env_b: dict, label_a: str, label_b: str) -> list[str]:
    rows = [
        ("Platform id", env_a.get("platform"), env_b.get("platform")),
        ("Host", env_a.get("host"), env_b.get("host")),
        ("Container", env_a.get("container"), env_b.get("container")),
        ("Kernel", _first_line(env_a.get("kernel")), _first_line(env_b.get("kernel"))),
        ("CPU governor", env_a.get("cpu", {}).get("governor"), env_b.get("cpu", {}).get("governor")),
        ("CPU max freq (kHz)", env_a.get("cpu", {}).get("max_freq_khz"), env_b.get("cpu", {}).get("max_freq_khz")),
        ("ROS_DISTRO", env_a.get("ros2", {}).get("ROS_DISTRO"), env_b.get("ros2", {}).get("ROS_DISTRO")),
        ("RMW_IMPLEMENTATION", env_a.get("ros2", {}).get("RMW_IMPLEMENTATION"), env_b.get("ros2", {}).get("RMW_IMPLEMENTATION")),
    ]
    out = [
        "## Fairness Statement\n",
        f"| Item | A: {label_a} | B: {label_b} |",
        "|---|---|---|",
    ]
    for name, a, b in rows:
        a_s = "—" if a in (None, "") else str(a)
        b_s = "—" if b in (None, "") else str(b)
        marker = " ⚠️" if a_s != b_s else ""
        out.append(f"| {name}{marker} | {a_s} | {b_s} |")
    out.append("")
    return out


def _power_w(metrics: dict[str, Any]) -> float | None:
    """Return average power in Watts if a power_w metric exists in this result."""
    pm = metrics.get("power_w")
    if isinstance(pm, dict):
        v = pm.get("avg") or pm.get("p50")
        if isinstance(v, (int, float)):
            return float(v)
    return None


def render_diffs(run_a: dict, run_b: dict) -> list[str]:
    a_b = run_a["benchmarks"]
    b_b = run_b["benchmarks"]
    all_ids = sorted(set(a_b) | set(b_b))
    if not all_ids:
        return ["_(no benchmarks found in either run)_\n"]

    lines = ["## Benchmark Deltas\n"]
    lines.append("Δ% is `(B - A) / A * 100`. Verdict prefers higher values unless the metric "
                 "name suggests lower-is-better (latency / jitter / power / temp / error / loss / miss).\n")
    lines.append("perf/W columns show `metric_primary / power_w_avg` when a `power_w` metric "
                 "is present in the same benchmark result.\n")

    for bid in all_ids:
        lines.append(f"### `{bid}`\n")
        a = a_b.get(bid)
        b = b_b.get(bid)
        if a is None:
            lines.append(f"_only present in B ({run_b['path'].name})_\n")
            continue
        if b is None:
            lines.append(f"_only present in A ({run_a['path'].name})_\n")
            continue
        a_metrics = a.get("metrics", {})
        b_metrics = b.get("metrics", {})
        names = sorted(set(a_metrics) | set(b_metrics))

        a_power = _power_w(a_metrics)
        b_power = _power_w(b_metrics)
        show_perf_w = a_power is not None or b_power is not None

        if show_perf_w:
            lines.append("| Metric | Unit | A | B | Δ | Δ% | A perf/W | B perf/W | Verdict |")
            lines.append("|---|---|---|---|---|---|---|---|---|")
        else:
            lines.append("| Metric | Unit | A | B | Δ | Δ% | Verdict |")
            lines.append("|---|---|---|---|---|---|---|")

        for name in names:
            am = a_metrics.get(name, {})
            bm = b_metrics.get(name, {})
            unit = am.get("unit") or bm.get("unit") or ""
            av = primary_value(am) if isinstance(am, dict) else None
            bv = primary_value(bm) if isinstance(bm, dict) else None
            if av is None or bv is None:
                if show_perf_w:
                    lines.append(f"| {name} | {unit} | {fmt(av)} | {fmt(bv)} | — | — | — | — | — |")
                else:
                    lines.append(f"| {name} | {unit} | {fmt(av)} | {fmt(bv)} | — | — | — |")
                continue
            delta = bv - av
            pct = (delta / av * 100.0) if av != 0 else float("inf")
            lower_better = is_lower_better(name)
            if delta == 0:
                verdict = "="
            elif (delta < 0) == lower_better:
                verdict = "B better"
            else:
                verdict = "A better"
            if show_perf_w:
                a_pw = fmt(av / a_power) if a_power and a_power > 0 and not is_lower_better(name) else "—"
                b_pw = fmt(bv / b_power) if b_power and b_power > 0 and not is_lower_better(name) else "—"
                lines.append(
                    f"| {name} | {unit} | {fmt(av)} | {fmt(bv)} | {fmt(delta)} | {pct:+.1f}% "
                    f"| {a_pw} | {b_pw} | {verdict} |"
                )
            else:
                lines.append(
                    f"| {name} | {unit} | {fmt(av)} | {fmt(bv)} | {fmt(delta)} | {pct:+.1f}% | {verdict} |"
                )
        lines.append("")
    return lines


def render_html(
    run_a: dict,
    run_b: dict,
    label_a: str,
    label_b: str,
    path_a: str,
    path_b: str,
) -> str:
    """Render a self-contained HTML comparison report (no external deps)."""
    import html as _html

    def h(s: str) -> str:
        return _html.escape(str(s))

    def fmt(v: Any) -> str:
        if v is None:
            return "—"
        if isinstance(v, float):
            return f"{v:.4g}"
        return str(v)

    rows_html: list[str] = []
    a_b = run_a["benchmarks"]
    b_b = run_b["benchmarks"]
    all_bids = sorted(set(a_b) | set(b_b))

    for bid in all_bids:
        a_doc = a_b.get(bid, {})
        b_doc = b_b.get(bid, {})
        a_metrics = a_doc.get("metrics", {})
        b_metrics = b_doc.get("metrics", {})
        all_names = sorted(set(a_metrics) | set(b_metrics))
        for name in all_names:
            am = a_metrics.get(name)
            bm = b_metrics.get(name)
            av = primary_value(am) if isinstance(am, dict) else None
            bv = primary_value(bm) if isinstance(bm, dict) else None
            unit = (am or bm or {}).get("unit", "")
            lower = is_lower_better(name)
            if av is not None and bv is not None and av != 0:
                pct = (bv - av) / abs(av) * 100.0
                better = (pct > 0 and not lower) or (pct < 0 and lower)
                colour = "#d4edda" if better else ("#f8d7da" if not better else "")
                verdict = "▲ B better" if better else "▼ A better"
                delta_s = f"{pct:+.1f}%"
            else:
                colour = "#fff"
                verdict = "—"
                delta_s = "—"
            rows_html.append(
                f'<tr style="background:{colour}">'
                f"<td>{h(bid)}</td><td>{h(name)}</td><td>{h(unit)}</td>"
                f"<td>{h(fmt(av))}</td><td>{h(fmt(bv))}</td>"
                f"<td>{h(delta_s)}</td><td>{h(verdict)}</td></tr>"
            )

    fairness_rows = ""
    env_a = run_a.get("env", {})
    env_b = run_b.get("env", {})
    compare_keys = ["platform", "kernel", "cpu_model", "ros_distro", "rmw"]
    for k in compare_keys:
        va = env_a.get(k, "—") or "—"
        vb = env_b.get(k, "—") or "—"
        warn = " ⚠️" if va != vb else ""
        fairness_rows += (
            f"<tr><td><code>{h(k)}</code></td>"
            f"<td>{h(str(va))}</td><td>{h(str(vb))}</td>"
            f"<td>{warn}</td></tr>"
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Comparison: {h(label_a)} vs {h(label_b)}</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 0; padding: 16px; background: #f8f9fa; }}
  h1 {{ font-size: 1.5em; }} h2 {{ font-size: 1.1em; margin-top: 24px; }}
  table {{ border-collapse: collapse; width: 100%; font-size: .9em; }}
  th {{ background: #343a40; color: white; padding: 6px 10px; text-align: left; }}
  td {{ padding: 5px 10px; border-bottom: 1px solid #dee2e6; }}
  tr:hover td {{ background: rgba(0,0,0,.04); }}
  .meta {{ color: #666; font-size: .85em; }}
</style>
</head>
<body>
<h1>📊 Comparison: {h(label_a)} vs {h(label_b)}</h1>
<p class="meta">A: <code>{h(path_a)}</code><br>B: <code>{h(path_b)}</code></p>

<h2>Fairness Check</h2>
<table>
<tr><th>Field</th><th>{h(label_a)} (A)</th><th>{h(label_b)} (B)</th><th>Match?</th></tr>
{fairness_rows}
</table>

<h2>Metric Comparison</h2>
<table>
<tr><th>Benchmark</th><th>Metric</th><th>Unit</th>
    <th>{h(label_a)} (A)</th><th>{h(label_b)} (B)</th><th>Δ B vs A</th><th>Verdict</th></tr>
{"".join(rows_html)}
</table>
</body>
</html>"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--a", required=True, help="path to run dir A")
    ap.add_argument("--b", required=True, help="path to run dir B")
    ap.add_argument("--out", required=True, help="output file path (.md or .html)")
    ap.add_argument("--charts", action="store_true",
                    help="also generate bar + radar PNG charts (requires matplotlib)")
    ap.add_argument("--format", choices=["markdown", "html"], default=None,
                    help="output format (default: inferred from --out extension)")
    args = ap.parse_args()

    run_a = load_run(Path(args.a))
    run_b = load_run(Path(args.b))

    label_a = run_a["env"].get("platform") or Path(args.a).parent.name
    label_b = run_b["env"].get("platform") or Path(args.b).parent.name

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    output_format = args.format
    if output_format is None:
        output_format = "html" if out.suffix.lower() == ".html" else "markdown"

    if output_format == "html":
        html_content = render_html(run_a, run_b, label_a, label_b, args.a, args.b)
        out.write_text(html_content, encoding="utf-8")
        print(f"wrote {out}")
    else:
        md: list[str] = []
        md.append(f"# Comparison: {label_a} vs {label_b}\n")
        md.append(f"- A: `{args.a}`")
        md.append(f"- B: `{args.b}`\n")
        md.extend(render_fairness(run_a["env"], run_b["env"], label_a, label_b))
        md.extend(render_diffs(run_a, run_b))
        out.write_text("\n".join(md), encoding="utf-8")
        print(f"wrote {out}")

    if args.charts:
        _write_charts(run_a, run_b, label_a, label_b, out)

    return 0


# ─── chart helpers ────────────────────────────────────────────────────────────

def _collect_ratios(
    run_a: dict, run_b: dict
) -> tuple[list[str], list[float]]:
    """Return (labels, ratios) where ratio = B/A normalised so >1 always means B is better.

    For lower-is-better metrics the ratio is inverted (A/B), so the chart is
    consistently "taller bar = better B".
    """
    labels: list[str] = []
    ratios: list[float] = []

    a_b = run_a["benchmarks"]
    b_b = run_b["benchmarks"]
    for bid in sorted(set(a_b) & set(b_b)):
        a_metrics = a_b[bid].get("metrics", {})
        b_metrics = b_b[bid].get("metrics", {})
        for name in sorted(set(a_metrics) & set(b_metrics)):
            am = a_metrics[name]
            bm = b_metrics[name]
            if not isinstance(am, dict) or not isinstance(bm, dict):
                continue
            av = primary_value(am)
            bv = primary_value(bm)
            if av is None or bv is None or av == 0:
                continue
            ratio = bv / av
            if is_lower_better(name):
                ratio = av / bv  # invert so >1 still means "B wins"
            short = f"{bid.split('.')[-1]}\n{name}"
            labels.append(short)
            ratios.append(ratio)
    return labels, ratios


def _write_charts(
    run_a: dict,
    run_b: dict,
    label_a: str,
    label_b: str,
    out_md: Path,
) -> None:
    try:
        import math
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("WARN: matplotlib / numpy not found; skipping charts (pip install matplotlib numpy)",
              file=sys.stderr)
        return

    labels, ratios = _collect_ratios(run_a, run_b)
    if not labels:
        print("WARN: no comparable metrics found for charts", file=sys.stderr)
        return

    stem = out_md.with_suffix("")

    # ── bar chart ─────────────────────────────────────────────────────────────
    fig, ax = plt.subplots(figsize=(max(8, len(labels) * 0.9), 5))
    colors = ["#e74c3c" if r < 1 else "#2ecc71" for r in ratios]
    x = np.arange(len(labels))
    ax.bar(x, ratios, color=colors, edgecolor="white", linewidth=0.5)
    ax.axhline(1.0, color="black", linewidth=0.8, linestyle="--", label="A = B")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=7, ha="center")
    ax.set_ylabel(f"B / A ratio  (>1 → {label_b} better)")
    ax.set_title(f"{label_a} vs {label_b} — normalised comparison\n"
                 "(lower-is-better metrics are inverted so >1 always means B wins)")
    ax.legend(fontsize=8)
    fig.tight_layout()
    bar_path = stem.parent / (stem.name + "-bar.png")
    fig.savefig(bar_path, dpi=150)
    plt.close(fig)
    print(f"wrote {bar_path}")

    # ── radar chart ───────────────────────────────────────────────────────────
    N = len(labels)
    if N < 3:
        print("WARN: fewer than 3 metrics — skipping radar chart", file=sys.stderr)
        return

    angles = np.linspace(0, 2 * math.pi, N, endpoint=False).tolist()
    # close the polygon
    ratios_closed = ratios + [ratios[0]]
    angles_closed = angles + [angles[0]]
    labels_closed = labels + [labels[0]]

    fig, ax = plt.subplots(figsize=(6, 6), subplot_kw={"polar": True})
    ax.plot(angles_closed, ratios_closed, "o-", linewidth=1.5, color="#2980b9")
    ax.fill(angles_closed, ratios_closed, alpha=0.25, color="#2980b9")
    ax.axhline(1.0, color="gray", linewidth=0.6, linestyle="--")
    ax.set_thetagrids(np.degrees(angles), [lb.replace("\n", " ") for lb in labels], fontsize=7)
    ax.set_title(
        f"{label_a} vs {label_b}\nRadar (>1 spoke = {label_b} better)",
        pad=20, fontsize=10,
    )
    radar_path = stem.parent / (stem.name + "-radar.png")
    fig.tight_layout()
    fig.savefig(radar_path, dpi=150)
    plt.close(fig)
    print(f"wrote {radar_path}")


if __name__ == "__main__":
    raise SystemExit(main())
