# `system/memory`

Memory bandwidth benchmark.

## What it measures

Peak DRAM copy bandwidth in MB/s, using the best available tool:

| Priority | Tool | Operation | Notes |
|---|---|---|---|
| 1 | `stream` / `stream_c` | Triad | Industry-standard DRAM bandwidth |
| 2 | `mbw` | MEMCPY | Good alternative when stream unavailable |
| 3 | Python `memoryview` | Byte copy | Conservative lower bound; no deps |

## Quick start

```bash
# Install stream (recommended):
sudo apt-get install -y stream
# or mbw:
sudo apt-get install -y mbw

./benchmarks/system/memory/run.sh \
    --platform=orin \
    --iterations=5 \
    --array-mb=512
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--iterations=N` | 5 | Number of measurement iterations |
| `--warmup=N` | 3 | Seconds to wait before first iteration |
| `--array-mb=N` | 512 | Array size in MB (stream uses its own compile-time size) |

## Output

`<run-dir>/system.memory.json` — single metric `bandwidth` (MB/s),
p50/p95/p99/min/max/avg/stdev.

## Why this matters for ROS 2

Memory bandwidth is the performance ceiling for large messages (point clouds,
images).  Orin LPDDR5 provides ~200 GB/s; comparing this against S100 reveals
whether 1 MB DDS messages will be transport-bound.
