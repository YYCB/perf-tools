# `e2e/slam`

End-to-end SLAM latency and accuracy benchmark.

> ⚠️ **Hardware required**: LiDAR or camera sensor, sufficient CPU/GPU for SLAM computation.

## What it measures

| Metric | Unit | Description |
|---|---|---|
| `scan_to_pose_ms` | ms | Sensor scan → pose update latency |
| `map_update_ms` | ms | Map insertion + optimization |
| `loop_closure_ms` | ms | Loop closure detection + correction |
| `slam_hz` | Hz | Sustained SLAM loop frequency |
| `cpu_utilization_pct` | % | CPU usage during SLAM |
| `memory_mb` | MB | RSS during SLAM |

## Supported SLAM systems

| System | Type | Package |
|---|---|---|
| Cartographer | LiDAR 2D | `ros-humble-cartographer-ros` |
| RTAB-Map | RGB-D / LiDAR 3D | `ros-humble-rtabmap-ros` |
| ORB-SLAM3 | Camera | build from source |
| LIO-SAM | LiDAR-IMU | build from source |

## Prerequisites

```bash
sudo apt-get install -y \
  ros-humble-cartographer-ros \
  ros-humble-rtabmap-ros
```

## Implementation plan (hardware-gated)

When hardware is available:
1. Play back a pre-recorded rosbag (ensures reproducibility across platforms)
2. Use `app-profiler` to monitor resource usage
3. Extract timing from SLAM diagnostics topics

Standard dataset: [TUM RGB-D](https://cvg.cit.tum.de/data/datasets/rgbd-dataset)
for reproducible cross-platform comparison.

```bash
# Rosbag-based reproducible benchmark
ros2 bag play slam_dataset.bag --clock &
./benchmarks/ros2/app-profiler/profile.sh \
    --process=cartographer_node \
    --session=slam-bench-orin
```

