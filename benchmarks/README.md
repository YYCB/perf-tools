# `benchmarks/` — runnable benchmarks

Three layers, mirroring `docs/methodology.md`:

| Subdir | Layer | Examples |
|---|---|---|
| [`system/`](system/) | hardware / OS | CPU, memory, storage, network, GPU, NPU, power-thermal |
| [`ros2/`](ros2/) | ROS 2 middleware | pub/sub latency, intra-process, DDS vendors, TF2, lifecycle |
| [`e2e/`](e2e/) | end-to-end task | perception pipeline, SLAM, Nav2 control loop |

## Contract every benchmark must satisfy

1. Provide an executable `run.sh` (or `run.py`).
2. Accept at minimum:
   - `--platform=<id>` (required)
   - `--run-dir=<dir>` (optional; if omitted, call `scripts/env-snapshot.sh` to make one)
3. Write a single JSON result file `<run-dir>/<benchmark.id>.json` matching
   [`docs/result-schema.md`](../docs/result-schema.md).
4. Repeat at least 5 iterations and report `p50` + `p95` + `stdev` (see
   [`docs/methodology.md`](../docs/methodology.md)).
5. Keep a raw output file `<run-dir>/<benchmark.id>.raw.txt` for forensics.

Use [`templates/benchmark-template/`](../templates/benchmark-template/) as a starting point.

## Status

### System benchmarks

| Benchmark | Status | Hardware required |
|---|---|---|
| `system/cpu/sysbench` | ✅ ready | any |
| `system/memory` | ✅ ready | any |
| `system/network` | ✅ ready | any (python3 fallback) |
| `system/storage` | ✅ ready | any (python3 fallback) |
| `system/power-thermal` | ✅ ready | platform telemetry tool |
| `system/npu` | ✅ ready | Orin / S100 / ONNX Runtime fallback |
| `system/gpu` | 📝 stub | GPU |

### ROS 2 benchmarks

| Benchmark | Status | Hardware required |
|---|---|---|
| `ros2/pubsub-latency` | ✅ ready | ROS 2 |
| `ros2/dds-vendors` | ✅ ready | ROS 2 + multiple RMWs |
| `ros2/intra-process` | ✅ ready | ROS 2 |
| `ros2/lifecycle-startup` | ✅ ready | ROS 2 |
| `ros2/tf2-throughput` | ✅ ready | ROS 2 + tf2_ros |
| `ros2/app-profiler` | ✅ ready | any + optional perf |

### E2E benchmarks

| Benchmark | Status | Hardware required |
|---|---|---|
| `e2e/nav2-loop` | 📝 stub | physical robot + Nav2 |
| `e2e/perception-pipeline` | 📝 stub | camera sensor + GPU |
| `e2e/slam` | 📝 stub | LiDAR/camera + SLAM stack |

