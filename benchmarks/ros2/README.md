# `benchmarks/ros2/` — ROS 2 middleware layer

| Subdir | Tools | Status |
|---|---|---|
| [`pubsub-latency/`](pubsub-latency/) | Apex.AI `performance_test` | M3 |
| [`intra-process/`](intra-process/) | custom; intra vs inter-process | M3 |
| [`dds-vendors/`](dds-vendors/) | matrix over FastDDS / CycloneDDS / Zenoh | M3 |
| [`tf2-throughput/`](tf2-throughput/) | custom | M3 |
| [`lifecycle-startup/`](lifecycle-startup/) | systemd-analyze + custom probes | M3 |

See [`docs/playbooks/ros2-dds-tuning.md`](../../docs/playbooks/ros2-dds-tuning.md).
