#!/usr/bin/env python3
"""collect-results.py — validate and index per-run JSON results.

Walks results/<platform>/<run-id>/*.json, validates against the minimal schema
defined in docs/result-schema.md, and writes results/<platform>/index.json
summarising every run for that platform.

Usage:
    python3 scripts/collect-results.py --platform=orin
    python3 scripts/collect-results.py --all
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"

REQUIRED_TOP_FIELDS = ("schema_version", "benchmark", "platform", "timestamp", "metrics")
SUPPORTED_SCHEMA_VERSIONS = {"1"}


def validate(doc: dict[str, Any], path: Path) -> list[str]:
    """Return list of validation errors (empty == OK)."""
    errors: list[str] = []
    for field in REQUIRED_TOP_FIELDS:
        if field not in doc:
            errors.append(f"missing field '{field}'")
    sv = doc.get("schema_version")
    if sv is not None and sv not in SUPPORTED_SCHEMA_VERSIONS:
        errors.append(f"unsupported schema_version '{sv}' (supported: {sorted(SUPPORTED_SCHEMA_VERSIONS)})")
    metrics = doc.get("metrics")
    if isinstance(metrics, dict):
        for name, m in metrics.items():
            if not isinstance(m, dict):
                errors.append(f"metric '{name}' is not an object")
                continue
            if "p50" not in m and "avg" not in m:
                errors.append(f"metric '{name}' missing both 'p50' and 'avg'")
            if "unit" not in m:
                errors.append(f"metric '{name}' missing 'unit'")
    elif "metrics" in doc:
        errors.append("'metrics' must be an object")
    return errors


def collect_for_platform(platform_dir: Path) -> dict[str, Any]:
    runs: list[dict[str, Any]] = []
    for run_dir in sorted(p for p in platform_dir.iterdir() if p.is_dir()):
        result_files = sorted(run_dir.glob("*.json"))
        try:
            rel_path = str(run_dir.relative_to(ROOT))
        except ValueError:
            rel_path = str(run_dir)
        run_entry = {
            "run_id": run_dir.name,
            "path": rel_path,
            "has_env": (run_dir / "env.json").exists(),
            "benchmarks": [],
            "errors": [],
        }
        for jf in result_files:
            if jf.name == "env.json":
                continue
            try:
                doc = json.loads(jf.read_text(encoding="utf-8"))
            except json.JSONDecodeError as e:
                run_entry["errors"].append(f"{jf.name}: invalid JSON ({e})")
                continue
            errs = validate(doc, jf)
            if errs:
                run_entry["errors"].extend(f"{jf.name}: {e}" for e in errs)
                continue
            run_entry["benchmarks"].append(
                {
                    "id": doc.get("benchmark"),
                    "file": jf.name,
                    "timestamp": doc.get("timestamp"),
                    "metrics": list(doc.get("metrics", {}).keys()),
                }
            )
        runs.append(run_entry)
    return {
        "schema_version": "1",
        "kind": "platform-index",
        "platform": platform_dir.name,
        "runs": runs,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--platform", help="platform id (subdir of --results-dir)")
    g.add_argument("--all", action="store_true", help="process every platform")
    ap.add_argument("--results-dir", default=str(RESULTS),
                    help=f"root results directory (default: {RESULTS})")
    args = ap.parse_args()

    results_root = Path(args.results_dir)
    if not results_root.exists():
        print(f"no results directory at {results_root}", file=sys.stderr)
        return 0

    if args.all:
        platforms = [p for p in results_root.iterdir() if p.is_dir()]
    else:
        p = results_root / args.platform
        if not p.is_dir():
            print(f"no results for platform '{args.platform}' at {p}", file=sys.stderr)
            return 1
        platforms = [p]

    overall_rc = 0
    for pdir in platforms:
        idx = collect_for_platform(pdir)
        out = pdir / "index.json"
        out.write_text(json.dumps(idx, indent=2, ensure_ascii=False), encoding="utf-8")
        n_runs = len(idx["runs"])
        n_errs = sum(len(r["errors"]) for r in idx["runs"])
        try:
            out_disp = out.relative_to(ROOT)
        except ValueError:
            out_disp = out
        print(f"[{pdir.name}] indexed {n_runs} runs, {n_errs} validation errors -> {out_disp}")
        if n_errs:
            for r in idx["runs"]:
                for e in r["errors"]:
                    print(f"  {r['run_id']}: {e}", file=sys.stderr)
            overall_rc = 1
    return overall_rc


if __name__ == "__main__":
    raise SystemExit(main())
