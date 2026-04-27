# `e2e/perception-pipeline`

End-to-end perception pipeline latency: camera sensor → preprocessing → inference → detection output.

> ⚠️ **Hardware required**: camera sensor (USB / MIPI CSI), GPU or NPU for inference.

## What it measures

| Metric | Unit | Description |
|---|---|---|
| `sensor_to_raw_ms` | ms | Camera capture → ROS image topic |
| `preprocessing_ms` | ms | Resize / normalize / format conversion |
| `inference_ms` | ms | Model forward pass (GPU/NPU) |
| `postprocessing_ms` | ms | NMS / decoding |
| `e2e_latency_ms` | ms | Camera shutter → detection result |
| `pipeline_fps` | Hz | Sustained throughput |

## Prerequisites

```bash
# Camera + GPU/NPU platform
# ROS 2 + image_transport + perception model (.onnx or platform-native)
sudo apt-get install -y \
  ros-humble-image-transport \
  ros-humble-cv-bridge \
  ros-humble-sensor-msgs
```

## Implementation plan (hardware-gated)

When hardware is available, the benchmark will:
1. Record timestamps at each pipeline stage using `header.stamp` or monotonic clock
2. Run N frames through the full pipeline
3. Output per-stage latency breakdown in `e2e.perception_pipeline.json`

The `ros2/app-profiler` can already be used for a manual equivalent:

```bash
# Profile an existing perception node
./benchmarks/ros2/app-profiler/profile.sh \
    --process=my_perception_node \
    --session=perception-bench
```

