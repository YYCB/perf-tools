# 地瓜 (Horizon Robotics) S100 平台档案

## 硬件规格（出厂标称）

| 项 | 值 |
|---|---|
| SoC | Horizon Journey 6 / Sunrise 系列（以 S100 为准） |
| CPU | Arm Cortex-A78AE × N（按 SKU 配置） |
| BPU | Horizon BPU（专有 NPU）, INT8 算力 80–560 TOPS（按 SKU） |
| 内存 | LPDDR5 |
| 存储 | eMMC / UFS / NVMe（按板卡） |

> 具体 SKU 与功耗模式以官方 datasheet 为准；测试时务必把 SKU 写进 `notes`。

## 关键工具

| 用途 | 命令 / 工具 |
|---|---|
| 实时遥测 | `hrut_soc` / `hrut_power`（厂家 SDK 提供） |
| 模型分析 | `hb_perf` / `hb_model_info`（HBDK / Compass） |
| BPU 利用率 | `hrut_soc bpu` / RDK OS 内置 dashboard |
| CPU 温度 | `cat /sys/class/thermal/thermal_zone*/temp` |
| CPU 频率锁定 | `echo performance > /sys/devices/system/cpu/cpufreq/policy*/scaling_governor` |

## 推荐 BSP / SDK

- RDK OS（基于 Ubuntu 22.04） — 与 Orin 对齐 ROS 2 Humble
- HBDK / Compass 模型工具链（INT8 量化 + BPU 编译）

## 跑测准备

```bash
# 1. 锁定 CPU performance governor
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
  echo performance | sudo tee "$f"
done

# 2. 采集环境快照
./scripts/env-snapshot.sh --platform=s100

# 3. 等待温度 < 50°C
watch -n2 "awk '{printf \"%.1f°C\\n\", \$1/1000}' /sys/class/thermal/thermal_zone0/temp"
```

## NPU 基准测试

```bash
# 需要先将 ONNX 模型量化编译成 .bin（离线完成）
hb_model_verifier --model model.bin --march bernini

./benchmarks/system/npu/run.sh \
    --platform=s100 \
    --model=model.bin \
    --batch=1 \
    --iterations=1000
```

## 功耗采集

```bash
# hrut_power 输出总输入功耗（单位 mW）
# 采样脚本示例
while true; do
  hrut_power 2>/dev/null | grep -o 'SOC:[0-9.]*' | head -1
  sleep 1
done | tee /tmp/s100_power.log &

./scripts/run-suite.sh --platform=s100 --suite=standard
kill %1

# 汇总
python3 - << 'PY'
import statistics
vals = []
for line in open('/tmp/s100_power.log'):
    try: vals.append(float(line.strip().split(':')[1]))
    except: pass
if vals: print(f"avg={statistics.fmean(vals):.1f}W  max={max(vals):.1f}W")
PY
```

## 已知陷阱

- ⚠️ BPU 算力高度依赖**模型量化与算子覆盖**；FP32 模型直接跑会落到 CPU
- ⚠️ 标称 TOPS 为 INT8 稀疏算力；实测 dense INT8 通常显著低于标称
- ⚠️ 官方 ROS 2 镜像与社区 Humble 可能存在 RMW 默认值差异，必须在 env.json 中固定
- ⚠️ 不同 SKU（80T / 120T / 560T 等）性能差异极大，报告中务必记录 SKU 型号

## ROS 2 注意事项

- 推荐与对比平台用同一 RMW（统一到 `rmw_cyclonedds_cpp`）
- BPU 推理节点建议放独立进程，避免 GIL / 大消息阻塞
- `export CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml`

## 参考链接

- 地瓜机器人开发者中心（Horizon RDK）
- HBDK / Compass 文档（厂家提供）

