# `system/network`

Loopback network throughput and latency benchmark.

## What it measures

TCP loopback throughput (Mbit/s) and UDP round-trip latency (µs), using the
best available tool:

| Priority | Tool | Metric | Notes |
|---|---|---|---|
| 1 | `iperf3` + `sockperf` | throughput + RTT latency | Industry standard |
| 2 | `sockperf` only | RTT latency (TCP ping-pong) | When iperf3 absent |
| 3 | Python `socket` | TCP loopback throughput | Conservative lower bound; no deps |

## Quick start

```bash
# Install recommended tools:
sudo apt-get install -y iperf3 sockperf

./benchmarks/system/network/run.sh \
    --platform=orin \
    --iterations=5 \
    --duration=10
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--duration=N` | 10 | Duration of each iperf3/sockperf run (seconds) |
| `--iterations=N` | 5 | Number of measurement iterations |
| `--warmup=N` | 2 | Warmup iterations (discarded) |

## Output

`<run-dir>/system.network.json` — metrics:
- `throughput` (Mbit/s): p50/p95/p99/min/max/avg/stdev — from iperf3 or Python
- `rtt_avg_us` (µs): p50/p95/p99/min/max/avg/stdev — from sockperf (when available)

## Why this matters for ROS 2

DDS transports large messages (images, point clouds) over UDP/TCP.  Loopback
throughput sets the upper bound for intra-host communication.  If loopback
throughput is already saturated, no DDS tuning will help.  Compare this number
against `ros2/pubsub-latency` 1 MB payload throughput to see how much DDS
overhead you are paying.
