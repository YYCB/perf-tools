# `system/storage`

Storage I/O benchmark (sequential throughput + random IOPS).

## What it measures

| Priority | Tool | Metrics | Notes |
|---|---|---|---|
| 1 | `fio` | seq write/read MB/s, rand write/read IOPS | Industry standard |
| 2 | Python `open()` | seq write/read MB/s | Conservative lower bound; no deps |

## Quick start

```bash
sudo apt-get install -y fio

./benchmarks/system/storage/run.sh \
    --platform=orin \
    --size=512M \
    --iterations=3
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--size=<sz>` | 512M | Test file size (K/M/G suffix) |
| `--iterations=N` | 3 | Number of measurement iterations |
| `--warmup=N` | 1 | Warmup iterations (discarded) |
| `--work-dir=<dir>` | `/tmp` | Directory to place the fio test file |

## Output

`<run-dir>/system.storage.json` — metrics:
- `seq_write_mb_s` (MB/s): sequential write throughput
- `seq_read_mb_s` (MB/s): sequential read throughput
- `rand_write_iops` (IOPS): 4K random write (fio only)
- `rand_read_iops` (IOPS): 4K random read (fio only)

## Why this matters for ROS 2

rosbag recording, log files, and model weights all hit storage.  Slow random
write IOPS causes dropped frames in the recording pipeline; slow sequential
read delays startup.  Compare across platforms to decide whether to use tmpfs
or a faster NVMe for the recording path.
