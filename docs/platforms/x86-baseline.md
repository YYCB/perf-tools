# x86 + dGPU 基线平台档案

> 状态：📝 stub。x86 平台主要作为 **基线参考**：当 SoC 上某项指标异常时，与 x86 对比有助于判断是硬件、内核还是应用瓶颈。

## 推荐基线配置

| 项 | 推荐 |
|---|---|
| CPU | Intel Core i9 / AMD Ryzen 9（≥ 12 核） |
| dGPU | NVIDIA RTX 4070 / 4090 |
| 内存 | 32 GB DDR5 |
| 存储 | NVMe Gen4 |
| OS | Ubuntu 22.04 LTS（与目标 SoC 对齐 ROS 2 distro） |

## 工具

- `nvidia-smi`、`nvidia-smi dmon`
- `perf`, `pcm`（Intel Performance Counter Monitor）
- `turbostat`（Intel）

## 注意事项

- ⚠️ x86 + dGPU 上 ROS 2 性能数据**不要**直接用来给 SoC 打分 —— 用作"理论上限"参考即可
- ⚠️ Turbo Boost / SMT 是否开启必须显式声明
