#!/usr/bin/env python3
"""regression.py — detect performance regressions against a stored baseline.

Usage:
    # First, save a run as the baseline:
    python3 scripts/regression.py save \
        --run-dir results/orin/2026-04-25T10-00-00Z \
        --baseline baselines/orin.json

    # Later, compare a new run against the baseline:
    python3 scripts/regression.py check \
        --run-dir results/orin/2026-04-26T10-00-00Z \
        --baseline baselines/orin.json \
        [--warn-pct=5] [--fail-pct=15] [--out=reports/regression.md]

Exit codes:
    0  all metrics within thresholds
    1  one or more metrics crossed --fail-pct
    2  one or more metrics crossed --warn-pct (but none crossed --fail-pct)

Regression logic:
    For higher-is-better metrics: regression = (baseline - current) / baseline * 100
    For lower-is-better metrics:  regression = (current - baseline) / baseline * 100
    Positive regression_pct = performance got worse.

The baseline JSON stores the p50 value for each (benchmark, metric) pair and
the run metadata so you can audit which run was used as the baseline.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

LOWER_BETTER_HINTS = ("latency", "jitter", "delay", "wakeup", "temp",
                      "power_w", "error", "loss", "miss", "rtt")


def is_lower_better(metric_name: str) -> bool:
    name = metric_name.lower()
    return any(h in name for h in LOWER_BETTER_HINTS)


def primary_value(metric: dict[str, Any]) -> float | None:
    for key in ("p50", "avg", "p95", "p99", "max"):
        v = metric.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def load_run(run_dir: Path) -> dict[str, Any]:
    """Load all benchmark JSONs from a run dir. Returns {benchmark_id: doc}."""
    if not run_dir.is_dir():
        sys.exit(f"ERROR: not a directory: {run_dir}")
    benchmarks: dict[str, Any] = {}
    for jf in sorted(run_dir.glob("*.json")):
        if jf.name in ("env.json", "index.json"):
            continue
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"WARN: skipping {jf.name}: {e}", file=sys.stderr)
            continue
        bid = doc.get("benchmark")
        if bid:
            benchmarks[bid] = doc
    return benchmarks


def extract_baseline_values(benchmarks: dict[str, Any]) -> dict[str, float]:
    """Flatten to {benchmark.metric: primary_value}."""
    flat: dict[str, float] = {}
    for bid, doc in benchmarks.items():
        for mname, mval in doc.get("metrics", {}).items():
            if not isinstance(mval, dict):
                continue
            v = primary_value(mval)
            if v is not None:
                flat[f"{bid}::{mname}"] = v
    return flat


def cmd_save(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    baseline_path = Path(args.baseline)
    benchmarks = load_run(run_dir)
    if not benchmarks:
        print(f"ERROR: no benchmark results found in {run_dir}", file=sys.stderr)
        return 1
    values = extract_baseline_values(benchmarks)
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline = {
        "source_run_dir": str(run_dir.resolve()),
        "platform": next(iter(benchmarks.values())).get("platform", "unknown"),
        "timestamp": next(iter(benchmarks.values())).get("timestamp", ""),
        "benchmarks": list(benchmarks.keys()),
        "values": values,
    }
    baseline_path.write_text(json.dumps(baseline, indent=2, ensure_ascii=False),
                             encoding="utf-8")
    print(f"saved baseline ({len(values)} metrics) -> {baseline_path}")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    baseline_path = Path(args.baseline)
    warn_pct = float(args.warn_pct)
    fail_pct = float(args.fail_pct)

    if not baseline_path.exists():
        print(f"ERROR: baseline not found: {baseline_path}", file=sys.stderr)
        return 1

    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    base_values: dict[str, float] = baseline.get("values", {})

    benchmarks = load_run(run_dir)
    if not benchmarks:
        print(f"ERROR: no benchmark results found in {run_dir}", file=sys.stderr)
        return 1

    current_values = extract_baseline_values(benchmarks)

    rows: list[dict[str, Any]] = []
    for key in sorted(set(base_values) | set(current_values)):
        bv = base_values.get(key)
        cv = current_values.get(key)
        bench, _, metric = key.partition("::")
        lower_better = is_lower_better(metric)

        if bv is None:
            rows.append({"key": key, "bench": bench, "metric": metric,
                         "baseline": None, "current": cv, "regr_pct": None,
                         "status": "NEW"})
            continue
        if cv is None:
            rows.append({"key": key, "bench": bench, "metric": metric,
                         "baseline": bv, "current": None, "regr_pct": None,
                         "status": "MISSING"})
            continue

        if bv == 0:
            regr_pct = 0.0
        elif lower_better:
            regr_pct = (cv - bv) / abs(bv) * 100.0
        else:
            regr_pct = (bv - cv) / abs(bv) * 100.0

        if regr_pct >= fail_pct:
            status = "FAIL"
        elif regr_pct >= warn_pct:
            status = "WARN"
        elif regr_pct <= -warn_pct:
            status = "IMPROVE"
        else:
            status = "OK"

        rows.append({"key": key, "bench": bench, "metric": metric,
                     "baseline": bv, "current": cv, "regr_pct": regr_pct,
                     "status": status})

    # Print to stdout
    header = f"{'Benchmark':<30} {'Metric':<28} {'Baseline':>12} {'Current':>12} {'Regr%':>8} Status"
    sep = "─" * len(header)
    print(sep)
    print(header)
    print(sep)

    n_fail = n_warn = n_improve = n_ok = 0
    for r in rows:
        bv_s = f"{r['baseline']:.3g}" if r['baseline'] is not None else "—"
        cv_s = f"{r['current']:.3g}" if r['current'] is not None else "—"
        rp_s = f"{r['regr_pct']:+.1f}%" if r['regr_pct'] is not None else "—"
        print(f"{r['bench']:<30} {r['metric']:<28} {bv_s:>12} {cv_s:>12} {rp_s:>8}  {r['status']}")
        if r["status"] == "FAIL":
            n_fail += 1
        elif r["status"] == "WARN":
            n_warn += 1
        elif r["status"] == "IMPROVE":
            n_improve += 1
        else:
            n_ok += 1
    print(sep)
    print(f"TOTAL: {len(rows)}  OK={n_ok}  IMPROVE={n_improve}  WARN={n_warn}  FAIL={n_fail}")
    print(f"Thresholds: warn≥{warn_pct}%  fail≥{fail_pct}%")
    print(f"Baseline: {baseline_path}  (run: {baseline.get('source_run_dir', '?')})")
    print(sep)

    if args.out:
        _write_markdown(rows, baseline, run_dir, warn_pct, fail_pct, Path(args.out))

    if n_fail:
        return 1
    if n_warn:
        return 2
    return 0


def _write_markdown(
    rows: list[dict],
    baseline: dict,
    run_dir: Path,
    warn_pct: float,
    fail_pct: float,
    out: Path,
) -> None:
    icon = {"OK": "✅", "IMPROVE": "🚀", "WARN": "⚠️", "FAIL": "❌",
            "NEW": "🆕", "MISSING": "❓"}
    lines: list[str] = [
        "# Regression Report\n",
        f"- **Baseline**: `{baseline.get('source_run_dir', '?')}`  "
        f"(saved: `{baseline.get('timestamp', '?')}`)",
        f"- **Current run**: `{run_dir}`",
        f"- **Thresholds**: warn ≥ {warn_pct}%  ·  fail ≥ {fail_pct}%\n",
        "| Benchmark | Metric | Baseline | Current | Regr% | Status |",
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        bv_s = f"{r['baseline']:.4g}" if r['baseline'] is not None else "—"
        cv_s = f"{r['current']:.4g}" if r['current'] is not None else "—"
        rp_s = f"{r['regr_pct']:+.1f}%" if r['regr_pct'] is not None else "—"
        ic = icon.get(r["status"], "")
        lines.append(
            f"| `{r['bench']}` | {r['metric']} | {bv_s} | {cv_s} | {rp_s} | {ic} {r['status']} |"
        )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {out}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp_save = sub.add_parser("save", help="save a run as the new baseline")
    sp_save.add_argument("--run-dir", required=True)
    sp_save.add_argument("--baseline", required=True,
                         help="path to write/overwrite the baseline JSON")

    sp_check = sub.add_parser("check", help="compare a run against the baseline")
    sp_check.add_argument("--run-dir", required=True)
    sp_check.add_argument("--baseline", required=True)
    sp_check.add_argument("--warn-pct", default=5, type=float,
                          help="regression %% threshold for WARN (default: 5)")
    sp_check.add_argument("--fail-pct", default=15, type=float,
                          help="regression %% threshold for FAIL (default: 15)")
    sp_check.add_argument("--out", help="optional Markdown report path")

    args = ap.parse_args()
    if args.cmd == "save":
        return cmd_save(args)
    return cmd_check(args)


if __name__ == "__main__":
    raise SystemExit(main())
