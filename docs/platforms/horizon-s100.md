# 地瓜 (Horizon Robotics) S100 平台档案

> 状态：📝 stub — 待 M2 阶段补全实测数据。

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
| 实时遥测 | `hrut_*` 系列工具（厂家 SDK 提供） |
| 模型分析 | `hb_perf` / `hb_model_info`（HBDK / Compass） |
| BPU 利用率 | RDK OS 内置 dashboard |

## 推荐 BSP / SDK

- RDK OS（基于 Ubuntu 22.04） — 与 Orin 对齐 ROS 2 Humble
- HBDK / Compass 模型工具链

## 已知陷阱

- ⚠️ BPU 算力高度依赖**模型量化与算子覆盖**；FP32 模型直接跑会落到 CPU
- ⚠️ 标称 TOPS 为 INT8 稀疏算力；实测 dense INT8 通常显著低于标称
- ⚠️ 官方 ROS 2 镜像与社区 Humble 可能存在 RMW 默认值差异，必须在 env.json 中固定

## ROS 2 注意事项

- 推荐与对比平台用同一 RMW（一般统一到 `rmw_cyclonedds_cpp`）
- BPU 推理节点建议放独立进程，避免 GIL / 大消息阻塞

## 参考链接

- 地瓜机器人开发者中心（Horizon RDK）
- HBDK / Compass 文档（厂家提供）

## TODO

- [ ] 补 SKU / 算力档位明细
- [ ] 实测 BPU 利用率脚本
- [ ] 与 Orin 对比的能效曲线
