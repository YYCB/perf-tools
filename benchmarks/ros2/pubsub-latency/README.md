# `ros2/pubsub-latency`

Measures ROS 2 one-way pub/sub latency via a ping-pong RTT/2 approach.

## What it measures

For each combination of payload size (1 KB / 64 KB / 1 MB) and QoS profile
(reliable+volatile, best_effort+volatile), the benchmark records N one-way
latency samples and emits p50/p95/p99/min/max/avg/stdev in microseconds.

## Files

| File | Purpose |
|---|---|
| `run.sh` | Shell launcher; sweeps payload × QoS matrix |
| `latency_probe.py` | rclpy ping-pong node pair (Pinger + Ponger) |

## Quick start

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

./benchmarks/ros2/pubsub-latency/run.sh \
    --platform=orin \
    --count=500 \
    --warmup=50
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier (orin / s100 / …) |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--count=N` | 500 | Samples to collect per case (after warmup) |
| `--warmup=N` | 50 | Messages to discard before recording |
| `--rate-hz=N` | 100 | Publish rate in Hz |
| `--payloads=…` | 1024,65536,1048576 | Comma-separated payload sizes in bytes |
| `--qos-pairs=…` | reliable+volatile,best_effort+volatile | Comma-separated QoS combos |

## Output

`<run-dir>/ros2.pubsub_latency.json` — schema-v1, one metric per case:
```
payload<bytes>_<reliability>_<durability>.latency_us
```

## Requires

- ROS 2 Humble+ (`ros2` on PATH, `rclpy` importable)
- `std_msgs` package
- Any RMW package (rmw_cyclonedds_cpp recommended)
