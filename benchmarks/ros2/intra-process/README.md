# `ros2/intra-process`

Compares ROS 2 intra-process communication latency against standard (inter-process) pub/sub.

## What it measures

| Mode | Description |
|---|---|
| `intra_<N>b` | Intra-process communication — zero-copy within one process |
| `inter_<N>b` | Standard pub/sub — full DDS transport (even on same host) |

One-way latency (µs) estimated as RTT/2 via ping-pong probe.

## Quick start

```bash
source /opt/ros/humble/setup.bash

./benchmarks/ros2/intra-process/run.sh \
    --platform=orin \
    --payloads=1024,65536,1048576 \
    --count=500
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--count=N` | 500 | Samples per case |
| `--warmup=N` | 50 | Warmup messages discarded |
| `--rate-hz=N` | 100 | Publish rate |
| `--payloads=CSV` | `1024,65536` | Comma-separated payload sizes (bytes) |

## Output

`<run-dir>/ros2.intra_process.json` — one metric per (mode, payload):
- `latency_intra_<N>b` (µs): intra-process latency
- `latency_inter_<N>b` (µs): inter-process latency

Compare intra vs inter to quantify DDS serialization + transport overhead.

## Why this matters

If `latency_intra_1MB` ≪ `latency_inter_1MB`, moving high-bandwidth nodes
(e.g., camera → detector) into the same process with intra-process enabled
can dramatically reduce CPU copy cost and latency.

