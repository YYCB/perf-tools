# `e2e/nav2-loop`

End-to-end Nav2 control-loop latency benchmark.

> ⚠️ **Hardware required**: physical or simulated robot with Navigation2 stack running.

## What it measures

The wall-clock latency of one complete navigation control loop iteration:
costmap update → planner → controller → cmd_vel publish.

| Metric | Unit | Description |
|---|---|---|
| `planner_latency_ms` | ms | Time from goal receipt to first cmd_vel |
| `controller_cycle_ms` | ms | Single controller loop iteration |
| `costmap_update_ms` | ms | Costmap full update cycle |
| `nav_loop_hz` | Hz | Sustained navigation loop frequency |

## Prerequisites

```bash
# ROS 2 Humble + Nav2
sudo apt-get install -y \
  ros-humble-navigation2 \
  ros-humble-nav2-bringup \
  ros-humble-turtlebot3-gazebo   # for simulation

# Or physical robot with Nav2 running
```

## Implementation plan (hardware-gated)

When hardware is available:

```bash
# 1. Launch Nav2 (Gazebo sim or real robot)
ros2 launch nav2_bringup navigation_launch.py

# 2. Run benchmark
./benchmarks/e2e/nav2-loop/run.sh \
    --platform=orin \
    --goal-count=20 \
    --waypoint-radius=0.5
```

The script will:
- Subscribe to `/diagnostics` and `/cmd_vel`
- Send N navigation goals
- Record planner/controller timing from Nav2 lifecycle and topic timestamps
- Output `e2e.nav2_loop.json`

