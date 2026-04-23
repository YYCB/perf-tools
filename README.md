# perf-tools

> 具身智能（机器人 / 自动驾驶 / 移动操作）平台性能优化工程师的开箱即用工具箱。
> A reproducible perf-benchmark toolkit for embodied-AI platforms — Linux + ROS 2, from silicon to end-to-end pipeline.

[English](#english) · [中文](#中文)

---

## 中文

### 仓库定位

- **使用者**：具身智能领域的性能优化 / 平台工程师
- **覆盖场景**：Linux（含嵌入式 Linux、Jetson Tegra、地瓜 RDK 等）+ ROS 2（Humble / Jazzy 为主）
- **核心价值**：
  1. **可复现** — 同一套脚本，任何人在任何硬件上跑出可比对的数字
  2. **跨平台对标** — Jetson AGX Orin ↔ Horizon S100 ↔ RK3588 ↔ Ascend ↔ x86+独显，用同一方法量化差异
  3. **全栈覆盖** — CPU / 内存 / GPU / NPU / IO / 功耗 / 散热 / ROS 2 通信 / 端到端任务延迟
  4. **沉淀经验** — 不止脚本，还包含方法论、调优 cheat sheet、典型瓶颈案例

### 快速上手

```bash
# 1. 采集本机环境快照（写入 results/<platform>/<date>/env.json）
./scripts/env-snapshot.sh --platform=orin

# 2. 跑一个最小闭环示例：sysbench CPU
./benchmarks/system/cpu/sysbench/run.sh --platform=orin

# 3. 归档结果
python3 scripts/collect-results.py --platform=orin

# 4. 与另一平台对比
python3 scripts/compare.py \
    --a results/orin/2026-04-23 \
    --b results/s100/2026-04-23 \
    --out reports/orin-vs-s100-2026-04.md
```

### 目录导航

| 路径 | 说明 |
|---|---|
| [`docs/methodology.md`](docs/methodology.md) | 基准测试方法论：环境隔离、热机、统计 |
| [`docs/metrics-glossary.md`](docs/metrics-glossary.md) | 指标词典：p50/p95/p99、jitter、TOPS 利用率… |
| [`docs/result-schema.md`](docs/result-schema.md) | 统一结果 JSON schema |
| [`docs/platforms/`](docs/platforms/) | 各硬件平台档案（Orin / S100 / RK3588 / x86） |
| [`docs/playbooks/`](docs/playbooks/) | 调优手册（DDS / RT 内核 / 散热功耗） |
| [`docs/case-studies/orin-vs-s100.md`](docs/case-studies/orin-vs-s100.md) | 招牌案例：Orin → S100 量化对比工作流 |
| [`benchmarks/system/`](benchmarks/system/) | 硬件层：CPU / 内存 / 存储 / 网络 / GPU / NPU / 功耗 |
| [`benchmarks/ros2/`](benchmarks/ros2/) | 中间件层：pub/sub 延迟、DDS 选型、TF2、生命周期 |
| [`benchmarks/e2e/`](benchmarks/e2e/) | 端到端：感知流水线、SLAM、Nav2 控制环 |
| [`scripts/`](scripts/) | 通用工具：env 快照、套件编排、归档、对比 |
| [`templates/`](templates/) | 新增 benchmark / 报告的脚手架 |
| [`results/`](results/) | 历史测试结果（按平台/日期归档） |
| [`reports/`](reports/) | 生成的对比报告（Markdown） |

### 路线图

| 阶段 | 范围 | 状态 |
|---|---|---|
| **M1** | 骨架 + 方法论 + 第一个最小闭环（sysbench） | ✅ 当前 |
| **M2** | 硬件层全套脚本 + Orin / S100 平台档案 + 第一份 baseline 报告 | ⬜ |
| **M3** | ROS 2 中间件套件（performance_test / DDS 三家 / TF2 / lifecycle） | ⬜ |
| **M4** | 端到端流水线 + GitHub Actions 自动回归 | ⬜ |

### 贡献

新增一个 benchmark：复制 [`templates/benchmark-template/`](templates/benchmark-template/)，按其中 `README.md` 指引填空即可。所有 benchmark 必须输出符合 [`docs/result-schema.md`](docs/result-schema.md) 的 JSON。

### 许可

待定（计划：Apache-2.0）。

---

## English

### What is this

A reproducible benchmark toolkit for performance engineers working on embodied-AI compute platforms (robotics, AD, mobile manipulation). It targets Linux + ROS 2 stacks across heterogeneous SoCs (Jetson, Horizon, Rockchip, Ascend, x86+dGPU) and covers the full stack — silicon, OS, middleware, end-to-end task pipelines.

### Quickstart

```bash
./scripts/env-snapshot.sh --platform=orin
./benchmarks/system/cpu/sysbench/run.sh --platform=orin
python3 scripts/collect-results.py --platform=orin
python3 scripts/compare.py --a results/orin/<date> --b results/s100/<date> --out reports/<name>.md
```

See [`docs/methodology.md`](docs/methodology.md) for the rules every benchmark must follow to produce comparable numbers, and [`docs/case-studies/orin-vs-s100.md`](docs/case-studies/orin-vs-s100.md) for the flagship workflow.
