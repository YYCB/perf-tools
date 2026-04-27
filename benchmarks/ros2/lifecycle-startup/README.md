# `ros2/lifecycle-startup`

Measures the wall-clock time for a ROS 2 LifecycleNode to advance through each state transition.

## What it measures

| Metric | Description |
|---|---|
| `configure_ms` | Unconfigured → Inactive |
| `activate_ms` | Inactive → Active |
| `deactivate_ms` | Active → Inactive |
| `cleanup_ms` | Inactive → Unconfigured |

All values in milliseconds (lower is better).

## Quick start

```bash
source /opt/ros/humble/setup.bash

./benchmarks/ros2/lifecycle-startup/run.sh \
    --platform=orin \
    --iterations=10
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--iterations=N` | 10 | Measurement iterations |
| `--warmup=N` | 2 | Warmup iterations discarded |
| `--node=<name>` | `perf_lifecycle_node` | Node name |

## Output

`<run-dir>/ros2.lifecycle_startup.json` — p50/p95/p99/min/max/avg/stdev for each transition.

## Why this matters

Slow lifecycle transitions delay system startup and recovery.  A robot that
takes > 5 s to transition Active after an E-stop recovery is unsafe.  This
benchmark surfaces misconfigured DDS discovery, heavy on_configure callbacks,
and blocking I/O at startup.

