# Scripts

Generic glue used by every benchmark and report.

| Script | Purpose |
|---|---|
| [`env-snapshot.sh`](env-snapshot.sh) | Collect host environment into `results/<platform>/<run-id>/env.json`; prints the run dir path on stdout |
| [`run-suite.sh`](run-suite.sh) | Orchestrate a `quick` or `full` benchmark suite for one platform |
| [`collect-results.py`](collect-results.py) | Validate every result JSON and write a `results/<platform>/index.json` summary |
| [`compare.py`](compare.py) | Diff two run directories, emit a Markdown report (with fairness statement + per-metric Δ%) |

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
```

## Conventions

- All scripts pass `--platform=<id>` and (where relevant) `--run-dir=<dir>`.
- A "run dir" is `results/<platform>/<UTC timestamp>/`, created by `env-snapshot.sh`.
- All result JSON files conform to [`docs/result-schema.md`](../docs/result-schema.md).
