# `benchmarks/e2e/` — end-to-end task layer

| Subdir | Workload | Status |
|---|---|---|
| [`perception-pipeline/`](perception-pipeline/) | rosbag replay → inference → /detection latency | M4 |
| [`slam/`](slam/) | KITTI / EuRoC dataset replay; runtime per frame | M4 |
| [`nav2-loop/`](nav2-loop/) | Nav2 control-loop jitter | M4 |
