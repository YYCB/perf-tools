# `config/` — DDS middleware configuration templates

Ready-to-use configuration files for ROS 2 DDS vendors, tuned for benchmark reproducibility.

## Files

| File | RMW | Notes |
|---|---|---|
| [`cyclonedds.xml`](cyclonedds.xml) | `rmw_cyclonedds_cpp` | Socket buffers, fragmentation, multicast, optional SCHED_FIFO threads |
| [`fastdds.xml`](fastdds.xml) | `rmw_fastrtps_cpp` | UDP + SHM transports, sync/async publisher profiles |

## Usage

### CycloneDDS

```bash
export CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

# Apply matching kernel settings (add to /etc/sysctl.d/99-ros2-dds.conf for persistence):
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.rmem_default=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

### FastDDS

```bash
export FASTRTPS_DEFAULT_PROFILES_FILE=$(pwd)/config/fastdds.xml
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
```

## Tuning guide

See [`docs/playbooks/ros2-dds-tuning.md`](../docs/playbooks/ros2-dds-tuning.md) for:
- RMW selection guidance
- Large-message (point cloud / image) tuning
- Real-time thread priority settings
- Multicast vs unicast tradeoffs

## Benchmark workflow

```bash
# Compare CycloneDDS vs FastDDS latency with these configs
CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml \
RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
./benchmarks/ros2/pubsub-latency/run.sh --platform=orin \
    --run-dir=results/orin/cyclone-$(date +%Y%m%dT%H%M%S)

FASTRTPS_DEFAULT_PROFILES_FILE=$(pwd)/config/fastdds.xml \
RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
./benchmarks/ros2/pubsub-latency/run.sh --platform=orin \
    --run-dir=results/orin/fastdds-$(date +%Y%m%dT%H%M%S)

python3 scripts/compare.py \
    --a results/orin/cyclone-* \
    --b results/orin/fastdds-* \
    --out reports/cyclone-vs-fastdds.md --charts
```
