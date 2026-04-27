# `ros2/tf2-throughput`

Measures TF2 transform lookup throughput and latency under two modes.

## What it measures

| Mode | Description |
|---|---|
| `buffer` | Pure in-process `tf2_ros.BufferCore` — no DDS overhead |
| `listener` | `tf2_ros.Buffer` via rclpy node + TF broadcaster — full DDS roundtrip |

Metrics:
- `<mode>_throughput_lookup_s` — lookups/second (higher is better)
- `<mode>_latency_us` — µs per lookup (lower is better)

## Quick start

```bash
source /opt/ros/humble/setup.bash

./benchmarks/ros2/tf2-throughput/run.sh \
    --platform=orin \
    --duration=30 \
    --depth=100 \
    --iterations=5
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--duration=N` | 30 | Seconds per iteration |
| `--depth=N` | 100 | Number of transforms in the buffer |
| `--iterations=N` | 5 | Measurement iterations |
| `--modes=CSV` | `buffer,listener` | Modes to run |

## Output

`<run-dir>/ros2.tf2_throughput.json` — throughput (lookups/s) and latency (µs) per mode.

## Why this matters

TF2 is called millions of times per second in a typical robot stack (every
sensor callback does a lookup).  If `buffer_throughput` is high but
`listener_throughput` is 10× lower, DDS subscriber overhead is the bottleneck
and you should investigate lock contention or buffer time_window settings.

