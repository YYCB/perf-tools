# x86 + dGPU 基线平台档案

> x86 平台作为**基线参考**：当 SoC 上某项指标异常时，与 x86 对比有助于判断是硬件、内核还是应用瓶颈。

## 推荐基线配置

| 项 | 推荐 |
|---|---|
| CPU | Intel Core i9 / AMD Ryzen 9（≥ 12 核） |
| dGPU | NVIDIA RTX 4070 / 4090（或等效 AMD） |
| 内存 | 32 GB DDR5 |
| 存储 | NVMe Gen4 (PCIe 4.0 ×4) |
| OS | Ubuntu 22.04 LTS（与目标 SoC 对齐 ROS 2 distro） |
| NIC | 1 GbE / 10 GbE（按网络测试需求） |

## 关键工具

| 用途 | 工具 |
|---|---|
| GPU 监控 | `nvidia-smi`、`nvidia-smi dmon -s pucvmet` |
| CPU 频率 / 功耗 | `turbostat --interval 1` (Intel)、`amd_energy` / `zenpower3` (AMD) |
| CPU 性能计数器 | `perf stat -a -e cache-misses,instructions,cycles` |
| Intel PCM | `pcm`（Intel Performance Counter Monitor） |
| 内存测试 | `stream`（DRAM 带宽）、`mbw` |
| RT 调度延迟 | `cyclictest -m -p80 -i200` |

## 频率锁定

```bash
# Intel: 禁用 Turbo Boost（稳态测量时）
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# 锁 performance governor
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$cpu"
done

# AMD: 禁用 CPB (Core Performance Boost)
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost

# 验证当前频率
turbostat --show Core,CPU,Avg_MHz,Busy%,PkgWatt --interval 2
```

## GPU 基线测试

```bash
# NVIDIA GPU 状态
nvidia-smi --query-gpu=name,memory.total,power.limit,clocks.max.sm \
  --format=csv

# 锁定 GPU 频率（稳定测量）
sudo nvidia-smi --lock-gpu-clocks=1200,1200  # 替换为实际最大频率

# GPU 计算性能（GFLOPS）参考
nvidia-smi --query-gpu=name,clocks.current.graphics,power.draw \
  --format=csv --loop=1
```

## ROS 2 基线配置

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml

# 增大内核 UDP 缓冲（大消息必须）
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

## 基线测试工作流

```bash
# 1. 系统基准（无需 GPU/NPU）
./scripts/run-suite.sh --platform=x86-baseline --suite=standard

# 2. 保存为基线
python3 scripts/regression.py save \
  --run-dir results/x86-baseline/<date> \
  --baseline baselines/x86-baseline.json

# 3. 与 Orin 对比
python3 scripts/compare.py \
  --a results/x86-baseline/<date> \
  --b results/orin/<date> \
  --out reports/x86-vs-orin.md --charts
```

## 注意事项

- ⚠️ x86 + dGPU 上 ROS 2 性能数据**不要**直接用来给 SoC 打分 — 用作"理论上限"参考
- ⚠️ Turbo Boost / SMT 是否开启必须显式声明（写入 env.json `notes` 字段）
- ⚠️ NUMA 拓扑：多路 CPU 的内存访问延迟差异大，跑测时用 `numactl --cpunodebind=0 --membind=0`
- ⚠️ SMM / C-states 会导致 RT 延迟尖峰：用 `hwlatdetect` 检测，必要时在 BIOS 关闭 C-states

