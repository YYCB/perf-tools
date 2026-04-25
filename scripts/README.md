# Scripts

Generic glue used by every benchmark and report.

| Script | Purpose |
|---|---|
| [`env-snapshot.sh`](env-snapshot.sh) | Collect host environment into `results/<platform>/<run-id>/env.json`; prints the run dir path on stdout |
| [`run-suite.sh`](run-suite.sh) | Orchestrate a `quick` or `full` benchmark suite for one platform |
| [`collect-results.py`](collect-results.py) | Validate every result JSON and write a `results/<platform>/index.json` summary |
| [`compare.py`](compare.py) | Diff two run directories, emit a Markdown report (with fairness statement + per-metric Δ%) |
| [`compare-app-profile.py`](compare-app-profile.py) | Diff two `app-profiler` session directories; emit a self-contained HTML with fairness statement, global & per-state stat deltas, and time-series overlay charts |

## Quick reference

```bash
# Single benchmark, single platform
./scripts/env-snapshot.sh --platform=orin
./benchmarks/system/cpu/sysbench/run.sh --platform=orin

# Full suite
./scripts/run-suite.sh --platform=orin --suite=quick

# Index + compare
python3 scripts/collect-results.py --platform=orin
python3 scripts/compare.py --a results/orin/<run> --b results/s100/<run> \
    --out reports/orin-vs-s100.md

# A/B comparison of two app-profiler sessions (e.g. feature on vs off,
# or v1 vs v2 of the same node)
python3 scripts/compare-app-profile.py \
    --a results/orin/baseline_<ts> \
    --b results/orin/feature-on_<ts> \
    --out reports/feature-ab.html
```

## Conventions

- All scripts pass `--platform=<id>` and (where relevant) `--run-dir=<dir>`.
- A "run dir" is `results/<platform>/<UTC timestamp>/`, created by `env-snapshot.sh`.
- All result JSON files conform to [`docs/result-schema.md`](../docs/result-schema.md).
