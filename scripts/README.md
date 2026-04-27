# Scripts

Generic glue used by every benchmark and report.

| Script | Purpose |
|---|---|
| [`env-snapshot.sh`](env-snapshot.sh) | Collect host environment into `results/<platform>/<run-id>/env.json`; prints the run dir path on stdout |
| [`install-deps.sh`](install-deps.sh) | Install all tool dependencies (sysbench, fio, iperf3, ROS 2, …) on Ubuntu/Debian |
| [`run-suite.sh`](run-suite.sh) | Orchestrate a `quick`, `standard`, or `full` benchmark suite for one platform |
| [`collect-results.py`](collect-results.py) | Validate every result JSON and write a `results/<platform>/index.json` summary |
| [`compare.py`](compare.py) | Diff two run directories, emit a Markdown report + optional bar/radar PNG charts |
| [`regression.py`](regression.py) | Save a run as baseline, then detect regressions in subsequent runs |
| [`trend.py`](trend.py) | Plot metric trends across many runs as a self-contained HTML file |
| [`compare-app-profile.py`](compare-app-profile.py) | Diff two `app-profiler` sessions; emit self-contained HTML with state stats + time-series charts |

## Quick reference

```bash
# 1. Install all dependencies
sudo ./scripts/install-deps.sh --ros-distro=humble

# 2. Single benchmark
./benchmarks/system/cpu/sysbench/run.sh --platform=orin

# 3. Standard suite (all system + ROS 2 benchmarks, no GPU/NPU)
./scripts/run-suite.sh --platform=orin --suite=standard

# 4. Index results + generate comparison report
python3 scripts/collect-results.py --platform=orin
python3 scripts/compare.py \
    --a results/orin/<run_a> --b results/s100/<run_b> \
    --out reports/orin-vs-s100.md --charts

# 5. Save a baseline and check for regressions
python3 scripts/regression.py save \
    --run-dir results/orin/<baseline_run> \
    --baseline baselines/orin.json
python3 scripts/regression.py check \
    --run-dir results/orin/<new_run> \
    --baseline baselines/orin.json \
    --warn-pct=5 --fail-pct=15 \
    --out reports/regression.md

# 6. Plot trend across all runs for a platform
python3 scripts/trend.py --platform=orin --out reports/orin-trend.html

# 7. A/B compare two app-profiler sessions
python3 scripts/compare-app-profile.py \
    --a results/orin/baseline_<ts> \
    --b results/orin/feature-on_<ts> \
    --out reports/feature-ab.html
```

## Conventions

- All scripts pass `--platform=<id>` and (where relevant) `--run-dir=<dir>`.
- A "run dir" is `results/<platform>/<UTC timestamp>/`, created by `env-snapshot.sh`.
- All result JSON files conform to [`docs/result-schema.md`](../docs/result-schema.md).
- The `standard` suite includes hardware-agnostic benchmarks (CPU, memory, network, storage);
  `full` discovers and runs every `run.sh` in the `benchmarks/` tree.

