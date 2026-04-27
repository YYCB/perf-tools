# `baselines/`

Baseline JSON files for regression detection.

Each file stores the p50 value for every metric in a reference run, allowing
`scripts/regression.py check` to detect regressions.

## Usage

```bash
# Save the current run as the platform baseline
python3 scripts/regression.py save \
    --run-dir results/orin/2026-04-25T10-00-00Z \
    --baseline baselines/orin.json

# Check a new run for regressions
python3 scripts/regression.py check \
    --run-dir results/orin/2026-04-26T10-00-00Z \
    --baseline baselines/orin.json \
    --warn-pct=5 --fail-pct=15 \
    --out reports/regression-orin.md
```

## Naming convention

`baselines/<platform>.json`  — latest accepted baseline for a platform

Commit these files so CI can always compare against a known-good state.

## Schema

```json
{
  "source_run_dir": "results/orin/2026-04-25T10-00-00Z",
  "platform": "orin",
  "timestamp": "2026-04-25T10:00:00Z",
  "benchmarks": ["system.cpu.sysbench", "system.memory", ...],
  "values": {
    "system.cpu.sysbench::events_per_sec": 10000.0,
    "system.memory::bandwidth": 50000.0
  }
}
```
