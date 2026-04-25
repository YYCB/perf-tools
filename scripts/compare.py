#!/usr/bin/env python3
"""compare.py — diff two run directories and emit a Markdown report.

Usage:
    python3 scripts/compare.py \
        --a results/orin/2026-04-23T17-00-00Z \
        --b results/s100/2026-04-23T17-00-00Z \
        --out reports/orin-vs-s100.md

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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--a", required=True, help="path to run dir A")
    ap.add_argument("--b", required=True, help="path to run dir B")
    ap.add_argument("--out", required=True, help="output Markdown path")
    args = ap.parse_args()

    run_a = load_run(Path(args.a))
    run_b = load_run(Path(args.b))

    label_a = run_a["env"].get("platform") or Path(args.a).parent.name
    label_b = run_b["env"].get("platform") or Path(args.b).parent.name

    md: list[str] = []
    md.append(f"# Comparison: {label_a} vs {label_b}\n")
    md.append(f"- A: `{args.a}`")
    md.append(f"- B: `{args.b}`\n")
    md.extend(render_fairness(run_a["env"], run_b["env"], label_a, label_b))
    md.extend(render_diffs(run_a, run_b))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(md), encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
