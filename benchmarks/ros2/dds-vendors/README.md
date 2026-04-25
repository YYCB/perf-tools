# `ros2/dds-vendors`

Compares ROS 2 pub/sub latency across DDS middleware implementations (RMW).

## What it measures

Runs `ros2/pubsub-latency` once per RMW in `--rmw-list`, then merges all
results into a single JSON whose metric keys are prefixed with the RMW name.
This makes it easy to see, for each payload and QoS combination, whether
CycloneDDS, FastDDS, or Zenoh performs better on a given platform.

## Quick start

```bash
source /opt/ros/humble/setup.bash

./benchmarks/ros2/dds-vendors/run.sh \
    --platform=orin \
    --rmw-list=rmw_cyclonedds_cpp,rmw_fastrtps_cpp \
    --count=500
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | Platform identifier |
| `--rmw-list=…` | rmw_cyclonedds_cpp,rmw_fastrtps_cpp | Comma-separated RMW packages |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--count=N` | 500 | Samples per case per RMW |
| `--warmup=N` | 50 | Warmup messages (discarded) |
| `--rate-hz=N` | 100 | Publish rate in Hz |
| `--payloads=…` | 1024,65536,1048576 | Payload sizes in bytes |
| `--qos-pairs=…` | reliable+volatile,best_effort+volatile | QoS combos |

## Output

`<run-dir>/ros2.dds_vendors.json` — metric keys pattern:
```
<rmw_name>.payload<bytes>_<reliability>_<durability>.latency_us
```

## Requires

- ROS 2 Humble+, rclpy, std_msgs
- The RMW packages you want to test (e.g. `ros-humble-rmw-cyclonedds-cpp`)

## See also

[`docs/playbooks/ros2-dds-tuning.md`](../../../docs/playbooks/ros2-dds-tuning.md)
