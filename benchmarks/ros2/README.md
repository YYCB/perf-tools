# `benchmarks/ros2/` — ROS 2 middleware layer

| Subdir | Description | Status |
|---|---|---|
| [`pubsub-latency/`](pubsub-latency/) | Pub/sub one-way latency sweep (payload × QoS) | ✅ ready |
| [`intra-process/`](intra-process/) | Intra-process vs inter-process latency comparison | ✅ ready |
| [`dds-vendors/`](dds-vendors/) | Matrix over FastDDS / CycloneDDS / Zenoh | ✅ ready |
| [`tf2-throughput/`](tf2-throughput/) | TF2 buffer lookup throughput & latency | ✅ ready |
| [`lifecycle-startup/`](lifecycle-startup/) | LifecycleNode state-transition timing | ✅ ready |
| [`app-profiler/`](app-profiler/) | Attach to any ROS 2 process, mark states, generate HTML report | ✅ ready |

See [`docs/playbooks/ros2-dds-tuning.md`](../../docs/playbooks/ros2-dds-tuning.md)
and DDS config templates in [`config/`](../../config/).

