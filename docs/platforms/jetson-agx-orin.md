# NVIDIA Jetson AGX Orin 平台档案

> 状态：📝 stub — 待 M2 阶段补全实测数据。

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

## 推荐 BSP / SDK

- JetPack 6.x（基于 Ubuntu 22.04） — 推荐
- CUDA 12.x、TensorRT 10.x、cuDNN 9.x

## 已知陷阱

- ⚠️ `nvpmodel` 切换后必须再次跑 `jetson_clocks`，否则频率不会拉到上限
- ⚠️ 默认 governor 是 `schedutil`，benchmark 前改为 `performance`
- ⚠️ tegrastats 报的 GPU% 是 SM 利用率，不反映显存带宽瓶颈
- ⚠️ DLA 走 TensorRT，必须显式 `--useDLACore=0`

## ROS 2 注意事项

- 官方 Isaac ROS / Jetson 容器使用 `dustynv/ros:humble-*` 镜像
- 默认 RMW 为 `rmw_fastrtps_cpp`；推荐切到 `rmw_cyclonedds_cpp` 测大消息延迟

## 参考链接

- [Jetson AGX Orin Developer Kit](https://developer.nvidia.com/embedded/jetson-agx-orin-developer-kit)
- [JetPack Documentation](https://docs.nvidia.com/jetson/jetpack/)
