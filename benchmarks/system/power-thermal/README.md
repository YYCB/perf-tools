# `system/power-thermal`

Measures sustained CPU power draw and die temperature under full load.

## What it measures

Starts a stress workload for `--duration` seconds, then samples power (W) and
temperature (°C) every `--interval` seconds via platform-specific tools.
Emits p50/p95/p99/min/max/avg/stdev/peak for both `power_w` and `temp_c`.

## Platform dispatch

| Platform | Power source | Temperature source |
|---|---|---|
| `orin` | `tegrastats` VDD_IN (mW → W) | `tegrastats` CPU@ |
| `s100` | `hrut_power` / `hrut_soc` | `hrut_soc` |
| other | `powerstat` (best-effort) | `/sys/class/thermal/thermal_zone0` |

## Quick start

```bash
./benchmarks/system/power-thermal/run.sh \
    --platform=orin \
    --duration=300 \
    --interval=5
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--duration=N` | 300 | Sampling duration in seconds |
| `--interval=N` | 5 | Seconds between samples |
| `--stress-cmd=…` | auto | Override the stress command |

## Output

`<run-dir>/system.power_thermal.json` — metrics `power_w` and `temp_c`.

The `power_w` metric in this file is used by `scripts/compare.py` to
automatically add **perf-per-W** columns when comparing benchmarks from the
same run directory.

## Requires

- `stress-ng` or `stress` for CPU load (`apt-get install -y stress-ng`)
- Platform telemetry tool (tegrastats / hrut_power / powerstat)
