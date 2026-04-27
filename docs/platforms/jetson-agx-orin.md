# NVIDIA Jetson AGX Orin 平台档案

## 硬件规格（出厂标称）

| 项 | 值 |
|---|---|
| SoC | NVIDIA Tegra T234 |
| CPU | 12× Arm Cortex-A78AE @ 2.2 GHz |
| GPU | Ampere, 2048 CUDA cores, 64 Tensor cores |
| NPU / DLA | 2× NVDLA v2 |
| 内存 | 64 GB LPDDR5, 256-bit, 204.8 GB/s |
| 存储 | 64 GB eMMC + NVMe (M.2 Key M) |
| 算力 | 275 TOPS (INT8, sparse) |
| 功耗模式 | 15 W / 30 W / 50 W / MAXN |

## 关键工具

| 用途 | 命令 |
|---|---|
| 设置功耗模式 | `sudo nvpmodel -m 0` (MAXN) |
| 锁定最高频率 | `sudo jetson_clocks` |
| 实时遥测 | `tegrastats --interval 1000` |
| 模型分析 | `trtexec --loadEngine=model.plan` |
| 系统监控 | `jtop`（来自 `pip install jetson-stats`） |
| CPU 频率查看 | `cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_cur_freq` |

## 推荐 BSP / SDK

- JetPack 6.x（基于 Ubuntu 22.04） — 推荐
- CUDA 12.x、TensorRT 10.x、cuDNN 9.x

## 跑测准备（每次必做）

```bash
# 1. 切最高功耗模式
sudo nvpmodel -m 0

# 2. 锁定所有频率（CPU / GPU / EMC / DLA）
sudo jetson_clocks

# 3. 采集环境快照（含 nvpmodel 状态）
./scripts/env-snapshot.sh --platform=orin

# 4. 等待温度稳定（< 50°C 起跑）
while [[ $(tegrastats --interval 100 | grep -o 'CPU@[0-9]*' | head -1 | tr -dc '0-9') -gt 50 ]]; do
  sleep 5; echo "cooling..."
done
```

## NPU 基准测试

```bash
# ONNX 模型（TensorRT 自动量化）
./benchmarks/system/npu/run.sh \
    --platform=orin \
    --model=model.onnx \
    --batch=1 \
    --iterations=1000

# 使用预编译 TensorRT engine（精确复现）
trtexec --loadEngine=model.plan --iterations=1000 --percentile=99
```

## 功耗采集

```bash
# tegrastats 解析：VDD_IN = 总输入功耗
sudo tegrastats --interval 1000 --logfile /tmp/tegrastats.log &
./scripts/run-suite.sh --platform=orin --suite=standard
kill %1

# 快速汇总
python3 - << 'PY'
import re, statistics
vals = [int(m.group(1)) / 1000.0
        for line in open('/tmp/tegrastats.log')
        for m in [re.search(r'VDD_IN (\d+)mW', line)] if m]
if vals:
    print(f"avg={statistics.fmean(vals):.1f}W  max={max(vals):.1f}W  p95={sorted(vals)[int(len(vals)*.95)]:.1f}W")
PY
```

## 已知陷阱

- ⚠️ `nvpmodel` 切换后必须再次跑 `jetson_clocks`，否则频率不会拉到上限
- ⚠️ 默认 governor 是 `schedutil`，benchmark 前改为 `performance`
- ⚠️ tegrastats 报的 GPU% 是 SM 利用率，不反映显存带宽瓶颈
- ⚠️ DLA 走 TensorRT，必须显式 `--useDLACore=0`
- ⚠️ `/proc/device-tree/nvidia,sku-id` 可读出 SKU，务必写入 env.json `notes`

## ROS 2 注意事项

- 官方 Isaac ROS / Jetson 容器使用 `dustynv/ros:humble-*` 镜像
- 默认 RMW 为 `rmw_fastrtps_cpp`；推荐切到 `rmw_cyclonedds_cpp` 测大消息延迟
- CycloneDDS 配置：`export CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml`

## 参考链接

- [Jetson AGX Orin Developer Kit](https://developer.nvidia.com/embedded/jetson-agx-orin-developer-kit)
- [JetPack Documentation](https://docs.nvidia.com/jetson/jetpack/)
- [tegrastats 字段说明](https://docs.nvidia.com/jetson/archives/r35.4.1/DeveloperGuide/text/SD/PlatformPowerAndPerformance/JetsonOrinNxSeriesAndJetsonAgxOrinSeries.html)

