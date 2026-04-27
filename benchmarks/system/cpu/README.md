# `system/cpu`

CPU performance benchmark suite.

## What it measures

| Benchmark | Tool | Primary metric |
|---|---|---|
| `system/cpu/sysbench` | sysbench | events/sec (single-thread & multi-thread) |

## Quick start

```bash
sudo apt-get install -y sysbench

./benchmarks/system/cpu/sysbench/run.sh \
    --platform=orin \
    --threads=1 \
    --duration=60 \
    --iterations=5
```

## Notes on multi-core heterogeneous SoCs

For SoCs with big/little cores (Orin A78AE, RK3588 A76+A55):

```bash
# Test big cores only (e.g. A76 on RK3588 = cpu4-7)
taskset -c 4-7 ./benchmarks/system/cpu/sysbench/run.sh \
    --platform=rk3588-bigcore --threads=4

# Test little cores only (e.g. A55 on RK3588 = cpu0-3)
taskset -c 0-3 ./benchmarks/system/cpu/sysbench/run.sh \
    --platform=rk3588-littlecore --threads=4
```

## Why this matters

CPU single-thread performance sets the latency floor for serial ROS 2 callback chains.
Multi-thread score measures parallel dispatch throughput.

