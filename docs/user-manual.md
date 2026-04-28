# perf-tools 用户手册 (User Manual)

> 版本：与 `results-schema v1` 同步，对应 commit `c64c003`（2026-04-27）  
> 适用平台：Jetson AGX Orin · Horizon S100 · RK3588 · x86+dGPU · 任意 Linux arm64/amd64

---

## 目录

1. [概述](#1-概述)
2. [快速上手（5 分钟闭环）](#2-快速上手5-分钟闭环)
3. [安装依赖](#3-安装依赖)
4. [目录结构](#4-目录结构)
5. [工具链参考](#5-工具链参考)
   - 5.1 [env-snapshot.sh — 环境快照](#51-env-snapshotsh-环境快照)
   - 5.2 [run-suite.sh — 套件编排](#52-run-suitesh-套件编排)
   - 5.3 [collect-results.py — 归档与验证](#53-collect-resultspy-归档与验证)
   - 5.4 [compare.py — 跨平台对比报告](#54-comparepy-跨平台对比报告)
   - 5.5 [regression.py — 基线保存与回归检测](#55-regressionpy-基线保存与回归检测)
   - 5.6 [trend.py — 多次跑趋势可视化](#56-trendpy-多次跑趋势可视化)
   - 5.7 [compare-app-profile.py — 应用剖析对比](#57-compare-app-profilepy-应用剖析对比)
6. [系统层 Benchmarks](#6-系统层-benchmarks)
   - 6.1 [CPU — sysbench](#61-cpu-sysbench)
   - 6.2 [内存带宽 — memory](#62-内存带宽-memory)
   - 6.3 [存储 I/O — storage](#63-存储-io-storage)
   - 6.4 [网络 — network](#64-网络-network)
   - 6.5 [NPU 推理 — npu](#65-npu-推理-npu)
   - 6.6 [功耗 & 散热 — power-thermal](#66-功耗-散热-power-thermal)
7. [ROS 2 中间件 Benchmarks](#7-ros-2-中间件-benchmarks)
   - 7.1 [pubsub-latency — 发布订阅延迟](#71-pubsub-latency-发布订阅延迟)
   - 7.2 [intra-process — 进程内通信对比](#72-intra-process-进程内通信对比)
   - 7.3 [dds-vendors — DDS 厂商横向对比](#73-dds-vendors-dds-厂商横向对比)
   - 7.4 [lifecycle-startup — 生命周期节点启动时间](#74-lifecycle-startup-生命周期节点启动时间)
   - 7.5 [tf2-throughput — TF2 变换查询吞吐量](#75-tf2-throughput-tf2-变换查询吞吐量)
   - 7.6 [app-profiler — 应用级在线剖析](#76-app-profiler-应用级在线剖析)
8. [端到端 Benchmarks（需硬件）](#8-端到端-benchmarks需硬件)
9. [结果 JSON Schema](#9-结果-json-schema)
10. [典型工作流](#10-典型工作流)
    - 10.1 [首次跑通 + 建立基线](#101-首次跑通-建立基线)
    - 10.2 [双平台横向对比](#102-双平台横向对比)
    - 10.3 [CI 回归门禁](#103-ci-回归门禁)
    - 10.4 [应用优化前后 A/B 对比](#104-应用优化前后-ab-对比)
11. [常见问题 (FAQ)](#11-常见问题-faq)
12. [增加新 Benchmark](#12-增加新-benchmark)
13. [退出码速查](#13-退出码速查)

---

## 1. 概述

**perf-tools** 是面向具身智能（机器人 / 自动驾驶 / 移动操作）平台性能工程师的开箱即用工具箱。

**核心价值**：

| 特性 | 说明 |
|---|---|
| 可复现 | 同一套脚本，任何人在任何硬件上跑出可比对的数字 |
| 跨平台对标 | Orin ↔ S100 ↔ RK3588 ↔ x86，用同一方法量化差异 |
| 全栈覆盖 | CPU / 内存 / GPU / NPU / IO / 功耗 / ROS 2 通信 / 端到端任务 |
| 沉淀经验 | 不止脚本，还包含方法论、调优 cheat sheet、典型案例 |
| python3 回退 | 所有系统 benchmark 在无第三方工具时都有 python3 回退，保证零依赖可运行 |

---

## 2. 快速上手（5 分钟闭环）

```bash
# ① 安装依赖（Ubuntu 22.04，仅第一次）
sudo ./scripts/install-deps.sh --ros-distro=humble

# ② 采集本机环境快照（写入 results/<platform>/<UTC时间戳>/env.json）
./scripts/env-snapshot.sh --platform=orin

# ③ 跑硬件无关的标准套件（CPU / 内存 / 网络 / 存储 + pubsub）
./scripts/run-suite.sh --platform=orin --suite=standard

# ④ 归档结果 + 验证 schema
python3 scripts/collect-results.py --platform=orin

# ⑤ 与另一平台对比（Markdown + HTML）
python3 scripts/compare.py \
    --a results/orin/2026-04-25T10-00-00Z \
    --b results/s100/2026-04-25T10-00-00Z \
    --out reports/orin-vs-s100.md --charts

# ⑥ 保存基线 + 后续回归检测
python3 scripts/regression.py save \
    --run-dir results/orin/2026-04-25T10-00-00Z \
    --baseline baselines/orin.json

python3 scripts/regression.py check \
    --run-dir results/orin/2026-04-27T10-00-00Z \
    --baseline baselines/orin.json \
    --warn-pct=5 --fail-pct=15

# ⑦ 多次跑趋势可视化
python3 scripts/trend.py --platform=orin --out reports/orin-trend.html
```

---

## 3. 安装依赖

```bash
sudo ./scripts/install-deps.sh [--ros-distro=humble] [--skip-ros]
```

| 选项 | 说明 |
|---|---|
| `--ros-distro=<distro>` | ROS 2 发行版（`humble` / `jazzy`，默认 `humble`） |
| `--skip-ros` | 跳过 ROS 2 安装（只装系统 benchmark 工具） |

安装内容：

| 类别 | 工具 |
|---|---|
| 系统 benchmark | `sysbench`, `fio`, `iperf3`, `sockperf`, `stress-ng` |
| 监控 | `sysstat`, `procps`, `lshw`, `numactl`, `cpufrequtils` |
| Python 可视化 | `matplotlib`, `numpy`（用于 `--charts`） |
| ROS 2（可选） | `ros-<distro>-ros-base`, `rclpy`, `std_msgs`, `tf2`, `lifecycle_msgs` |
| 火焰图（可选） | `perf` + FlameGraph（brendangregg/FlameGraph） |

> **stream** 需手动编译（`cs.virginia.edu/stream`），或 `apt-get install stream`（部分发行版）。

---

## 4. 目录结构

```
perf-tools/
├── benchmarks/
│   ├── system/          # 硬件层：cpu / memory / storage / network / npu / power-thermal
│   ├── ros2/            # 中间件层：pubsub / intra-process / dds-vendors / tf2 / lifecycle / app-profiler
│   └── e2e/             # 端到端：nav2-loop / slam / perception-pipeline（需硬件）
├── config/              # DDS 配置模板（cyclonedds.xml / fastdds.xml）
├── docs/                # 方法论 / schema / 平台档案 / 调优手册 / 案例
├── results/             # 历史测试结果（results/<platform>/<run-id>/）
├── baselines/           # 保存的基线 JSON（baselines/<platform>.json）
├── reports/             # 生成的对比报告
├── scripts/             # 通用工具链（见第 5 节）
└── templates/           # 新增 benchmark / 报告的脚手架
```

### 运行目录约定

每次运行的所有输出**必须**放在同一个"运行目录"下：

```
results/<platform>/<YYYY-MM-DDTHH-MM-SSZ>/
├── env.json                    ← 环境快照（env-snapshot.sh 自动创建）
├── system.cpu.sysbench.json    ← 一个 benchmark 一个 JSON
├── system.cpu.sysbench.raw.txt ← 工具原始输出（可选）
├── system.memory.json
└── ...
```

所有 `--run-dir` 参数都接受这个路径。不传 `--run-dir` 时，脚本会自动调用 `env-snapshot.sh` 创建它。

---

## 5. 工具链参考

### 5.1 `env-snapshot.sh` — 环境快照

```bash
./scripts/env-snapshot.sh --platform=<id> [--out-dir=results]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--platform=<id>` | **必填** | 平台标识，如 `orin` / `s100` / `rk3588` / `x86` |
| `--out-dir=<path>` | `results` | 结果根目录 |

**行为**：创建 `<out-dir>/<platform>/<UTC时间戳>/env.json`，并将运行目录路径打印到 stdout（可用 `$()` 捕获）。

**输出字段**：`platform`, `run_id`, `host`, `container`, `kernel`, `os_release`, `cpu`（governor/频率）, `memory`, `thermal_milli_c`, `vendor_power`（Jetson nvpmodel / Horizon hrut），`io`（lsblk/lspci/lsusb），`ros2` 环境变量。

**捕获运行目录**：

```bash
RUNDIR=$(./scripts/env-snapshot.sh --platform=orin)
# 然后把 RUNDIR 传给各个 benchmark
./benchmarks/system/cpu/sysbench/run.sh --platform=orin --run-dir="${RUNDIR}"
```

---

### 5.2 `run-suite.sh` — 套件编排

```bash
./scripts/run-suite.sh \
    --platform=<id> \
    [--suite=quick|standard|full] \
    [--out-dir=results] \
    [--timeout=600] \
    [--fail-fast]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--platform=<id>` | **必填** | 平台标识 |
| `--suite=<name>` | `quick` | 套件名（见下表） |
| `--out-dir=<path>` | `results` | 结果根目录，传给 `env-snapshot.sh` |
| `--timeout=<N>` | `600` | 单个 benchmark 超时（秒），`0` 表示无限制 |
| `--fail-fast` | 关 | 遇到第一个失败后立即退出 |

**套件说明**：

| 套件 | 内容 | 硬件要求 |
|---|---|---|
| `quick` | sysbench CPU（约 1 分钟） | 无特殊要求（有 python3 回退） |
| `standard` | CPU + 内存 + 网络 + 存储 + pubsub 延迟 | 无特殊要求（全有 python3 回退，pubsub 需 ROS 2） |
| `full` | 自动发现 `benchmarks/` 下所有可执行 `run.sh` | 需平台特定硬件（NPU / 散热工具等） |

**退出码**：`0` = 所有 benchmark 通过；非零 = 有失败（`fail` 计数 > 0）。

---

### 5.3 `collect-results.py` — 归档与验证

```bash
python3 scripts/collect-results.py \
    (--platform=<id> | --all) \
    [--results-dir=results]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--platform=<id>` | — | 处理单个平台 |
| `--all` | — | 处理所有平台（与 `--platform` 互斥） |
| `--results-dir=<path>` | `results` | 结果根目录 |

**行为**：遍历 `results/<platform>/<run-id>/*.json`，验证每个文件是否符合 schema v1，汇总写入 `results/<platform>/index.json`。

**退出码**：`0` = 无验证错误；`1` = 有 schema 错误（错误明细打印到 stderr）。

**index.json 结构**：

```json
{
  "schema_version": "1",
  "kind": "platform-index",
  "platform": "orin",
  "runs": [
    {
      "run_id": "2026-04-25T10-00-00Z",
      "path": "results/orin/2026-04-25T10-00-00Z",
      "has_env": true,
      "benchmarks": [
        {"id": "system.cpu.sysbench", "file": "...", "timestamp": "...", "metrics": ["events_per_sec"]}
      ],
      "errors": []
    }
  ]
}
```

---

### 5.4 `compare.py` — 跨平台对比报告

```bash
python3 scripts/compare.py \
    --a <run-dir-A> \
    --b <run-dir-B> \
    --out <report.md | report.html> \
    [--charts] \
    [--format=markdown|html]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--a <path>` | **必填** | 运行目录 A |
| `--b <path>` | **必填** | 运行目录 B |
| `--out <path>` | **必填** | 输出文件；扩展名为 `.html` 时自动选 HTML 格式 |
| `--charts` | 关 | 同时输出 PNG 条形图 + 雷达图（需 `matplotlib`） |
| `--format=<fmt>` | 从扩展名推断 | `markdown` 或 `html` |

**输出内容**：

- **公平性声明**（fairness statement）：对比两侧的 platform / kernel / CPU governor / ROS_DISTRO / RMW
- **指标差异表**：每行包含 metric name, unit, A, B, Δ, Δ%, verdict（A better / B better / =）
- **功耗效率列**（perf/W）：当 benchmark 包含 `power_w` 指标时自动追加

**高低优判断规则**：metric 名含 `latency` / `jitter` / `delay` / `temp` / `power_w` / `error` / `loss` / `miss` → 低优先（lower-is-better）；其余 → 高优先。

---

### 5.5 `regression.py` — 基线保存与回归检测

#### 保存基线

```bash
python3 scripts/regression.py save \
    --run-dir <path> \
    --baseline <baselines/orin.json>
```

从运行目录读取所有 benchmark JSON，提取每个 `benchmark::metric` 的 p50 值，存入指定的基线文件。

#### 检测回归

```bash
python3 scripts/regression.py check \
    --run-dir <path> \
    --baseline <baselines/orin.json> \
    [--warn-pct=5] \
    [--fail-pct=15] \
    [--out=reports/regression.md]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--warn-pct=<N>` | `5` | 回归百分比达到此值 → `WARN` |
| `--fail-pct=<N>` | `15` | 回归百分比达到此值 → `FAIL` |
| `--out=<path>` | — | 可选：输出 Markdown 报告 |

**退出码**：

| 退出码 | 含义 |
|---|---|
| `0` | 所有指标在阈值内（含 OK 和 IMPROVE） |
| `1` | 至少一个指标超过 `--fail-pct` |
| `2` | 至少一个指标超过 `--warn-pct`（无 FAIL） |

**回归计算方式**：

- 高优先指标（越大越好）：`regr% = (baseline - current) / |baseline| × 100`
- 低优先指标（越小越好）：`regr% = (current - baseline) / |baseline| × 100`
- 正值表示性能变差。

---

### 5.6 `trend.py` — 多次跑趋势可视化

```bash
python3 scripts/trend.py \
    --platform=<id> \
    [--results-dir=results] \
    [--metrics=bench::metric,bench::metric,...] \
    [--last=20] \
    --out <reports/orin-trend.html>
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--platform=<id>` | **必填** | 平台标识 |
| `--results-dir=<path>` | `results` | 结果根目录（需先跑 `collect-results.py`） |
| `--metrics=<list>` | 全部发现的指标 | 逗号分隔，格式 `benchmark_id::metric_name` |
| `--last=<N>` | `0`（全部） | 只展示最近 N 次运行 |
| `--out=<path>` | **必填** | 输出 HTML 路径 |

**前置条件**：必须先运行 `collect-results.py --platform=<id>` 生成 `results/<platform>/index.json`。

**输出**：自包含 HTML（无外部依赖，可离线打开），每个指标一张时间序列折线图，自动着色。

---

### 5.7 `compare-app-profile.py` — 应用剖析对比

```bash
python3 scripts/compare-app-profile.py \
    --a <session-dir-A> \
    --b <session-dir-B> \
    [--label-a=baseline] \
    [--label-b=feature-on] \
    [--out=reports/compare.html]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--a / --b` | **必填** | `app-profiler/profile.sh` 生成的会话目录 |
| `--label-a / --label-b` | 从目录名推断 | 报告中的标签 |
| `--out=<path>` | `<a>/compare.html` | 输出自包含 HTML |

**输入文件**（会话目录中）：`metrics.jsonl`（时间序列），`states.jsonl`（状态边界），`env.json`。

**报告内容**：公平性对比 → 全局汇总表（CPU/RSS/线程数/FD 数，含 Δ%）→ 按 state 对比表 → 双轨时序图（两个会话叠加在同一坐标轴）。

---

## 6. 系统层 Benchmarks

所有系统 benchmark 遵循同一调用约定：

```bash
./benchmarks/system/<name>/run.sh \
    --platform=<id> \
    [--run-dir=<path>]  # 不填则自动创建
    [<benchmark-specific args>]
```

### 6.1 CPU — sysbench

```bash
./benchmarks/system/cpu/sysbench/run.sh \
    --platform=orin \
    [--threads=N]        # 默认 nproc
    [--duration=10]      # 每次迭代秒数
    [--iterations=5]     # 重复次数
    [--warmup=3]         # 预热秒数（丢弃）
    [--prime=20000]      # 质数上界（sysbench cpu-max-prime）
```

**工具优先级**：`sysbench` → python3 多线程质数筛（保守下界，约 10–100× 慢于 sysbench）

**输出指标**：`events_per_sec`（1/s）

**注意**：python3 回退值为保守下界，`notes` 字段有明确说明；用于无 sysbench 环境的 CI 验证，**不**可与 sysbench 真实值直接比较趋势。

---

### 6.2 内存带宽 — memory

```bash
./benchmarks/system/memory/run.sh \
    --platform=orin \
    [--iterations=5] \
    [--warmup=3] \
    [--array-mb=512]     # 测试数组大小（MB）
```

**工具优先级**：`stream` / `stream_c` → `mbw` → python3 memoryview 拷贝

**输出指标**：`bandwidth`（MB/s）

---

### 6.3 存储 I/O — storage

```bash
./benchmarks/system/storage/run.sh \
    --platform=orin \
    [--size=512M]        # 测试文件大小
    [--iterations=3] \
    [--warmup=1] \
    [--work-dir=/tmp]    # 测试文件写入目录（需有 2× size 空闲空间）
```

**工具优先级**：`fio` → python3 顺序读写

**输出指标**（fio 时）：`seq_write_mb_s`, `seq_read_mb_s`, `rand_write_iops`, `rand_read_iops`  
**输出指标**（python3 回退时）：`seq_write_mb_s`, `seq_read_mb_s`（仅顺序）

---

### 6.4 网络 — network

```bash
./benchmarks/system/network/run.sh \
    --platform=orin \
    [--duration=10]      # 每次迭代秒数
    [--iterations=5] \
    [--warmup=2]
```

**工具优先级**：`iperf3`（TCP 吞吐）+ `sockperf`（UDP RTT 延迟）→ python3 TCP 环回吞吐

**输出指标**：`throughput`（Mbit/s）；sockperf 可用时额外输出 `latency_rtt_us`（µs）

---

### 6.5 NPU 推理 — npu

```bash
./benchmarks/system/npu/run.sh \
    --platform=orin \
    --model=/path/to/model.onnx \
    [--run-dir=<dir>] \
    [--iterations=100] \
    [--warmup=10]
```

| 参数 | 说明 |
|---|---|
| `--model=<path>` | Orin/x86：`.onnx`；S100：已编译 `.bin` |
| `--iterations=<N>` | 推理次数 |
| `--warmup=<N>` | 预热次数 |

**平台分发**：`orin` → `trtexec`（JetPack TensorRT）；`s100` → `hb_perf`（Horizon BPU）；其他 → `onnxruntime` CPU 回退

**输出指标**：`inference_latency`（µs 或 ms），`throughput_fps_derived`（fps）

---

### 6.6 功耗 & 散热 — power-thermal

```bash
./benchmarks/system/power-thermal/run.sh \
    --platform=orin \
    [--duration=300]     # 压测 + 采样总时长（秒）
    [--interval=5]       # 采样间隔（秒）
    [--stress-cmd="stress-ng --cpu 0 --timeout 300s"]
```

**平台分发**：`orin` → `tegrastats`；`s100` → `hrut_soc` / `hrut_power`；其他 → `/sys/class/thermal` + `powerstat`

**输出指标**：`power_w`（W），`temp_cpu_c`（°C），`temp_board_c`（°C）

---

## 7. ROS 2 中间件 Benchmarks

所有 ROS 2 benchmark 需要先 source ROS 2 环境：

```bash
source /opt/ros/humble/setup.bash
# 可选：选择 RMW
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

### 7.1 `pubsub-latency` — 发布订阅延迟

```bash
./benchmarks/ros2/pubsub-latency/run.sh \
    --platform=orin \
    [--count=500]        # 每 case 样本数
    [--warmup=50]        # 预热样本（丢弃）
    [--rate-hz=100]      # 发布频率
    [--payloads=1024,65536,1048576]  # 测试 payload（字节，逗号分隔）
    [--qos-pairs=reliable+volatile,best_effort+volatile]
```

**原理**：ping-pong RTT/2 单向延迟测量（`latency_probe.py`）

**输出指标**（每个 payload × QoS 组合）：`latency_us`（p50/p95/p99/min/max/stdev，µs）

**结果文件**：`ros2.pubsub_latency.json`

---

### 7.2 `intra-process` — 进程内通信对比

```bash
./benchmarks/ros2/intra-process/run.sh \
    --platform=orin \
    [--count=500] \
    [--warmup=50] \
    [--rate-hz=100] \
    [--payloads=1024,65536]
```

**原理**：对同一 payload 分别跑进程内（intra-process）和进程间（inter-process）测量，结果合并到同一 JSON，`compare.py` 可直接对比。

**结果文件**：`ros2.intra_process.json`

---

### 7.3 `dds-vendors` — DDS 厂商横向对比

```bash
./benchmarks/ros2/dds-vendors/run.sh \
    --platform=orin \
    [--rmw-list=rmw_cyclonedds_cpp,rmw_fastrtps_cpp] \
    [--count=500] \
    [--warmup=50] \
    [--rate-hz=100] \
    [--payloads=1024,65536,1048576] \
    [--qos-pairs=reliable+volatile,best_effort+volatile]
```

**原理**：对每个 RMW 依次跑 `pubsub-latency`，指标 key 以 RMW 名前缀区分，合并到单一 JSON。

**结果文件**：`ros2.dds_vendors.json`

---

### 7.4 `lifecycle-startup` — 生命周期节点启动时间

```bash
./benchmarks/ros2/lifecycle-startup/run.sh \
    --platform=orin \
    [--iterations=10] \
    [--warmup=2] \
    [--node=perf_lifecycle_node]
```

**原理**：`ros2 lifecycle` CLI 驱动状态转换，纳秒精度计时。

**输出指标**：`configure_ms`, `activate_ms`, `deactivate_ms`, `cleanup_ms`, `shutdown_ms`（ms）

**结果文件**：`ros2.lifecycle_startup.json`

---

### 7.5 `tf2-throughput` — TF2 变换查询吞吐量

```bash
./benchmarks/ros2/tf2-throughput/run.sh \
    --platform=orin \
    [--duration=30] \
    [--depth=100]        # TF 链深度
    [--iterations=5] \
    [--modes=buffer,listener]
```

| 模式 | 说明 |
|---|---|
| `buffer` | 纯进程内 `tf2.BufferCore`，测量原始吞吐（无 DDS 开销） |
| `listener` | `tf2_ros.Buffer` 订阅模式，含完整 DDS 往返 |

**输出指标**：`lookups_per_sec`（1/s），`lookup_latency_us`（µs）

**结果文件**：`ros2.tf2_throughput.json`

---

### 7.6 `app-profiler` — 应用级在线剖析

```bash
./benchmarks/ros2/app-profiler/profile.sh \
    [--pid=PID | --process=NAME | --ros-node=NODE_NAME] \
    --session=<name> \
    [--platform=<id>] \
    [--interval-ms=500] \
    [--out-dir=results] \
    [--flamegraph]       # 需要 perf + FlameGraph
```

**原理**：附加到正在运行的 ROS 2 进程，持续采样 CPU%、RSS、线程数、FD 数。交互式操作：

```
> start <state-name>   # 标记一个状态区间的开始
> end                  # 结束当前状态区间
> q                    # 停止采样，自动生成 HTML 报告
```

**输出**：
- `metrics.jsonl`（时序样本）
- `states.jsonl`（状态区间）
- `env.json`（环境快照）
- `ros2.app-profiler.json`（schema v1 汇总）
- `report.html`（自包含 HTML 报告）

**配合 `compare-app-profile.py`** 对两次会话做 A/B 对比（见 [5.7](#57-compare-app-profilepy-应用剖析对比)）。

---

## 8. 端到端 Benchmarks（需硬件）

| Benchmark | 路径 | 内容 |
|---|---|---|
| Nav2 定点导航 | `benchmarks/e2e/nav2-loop/` | 从 A→B→A 往返，量化 p95 到达延迟 |
| SLAM 建图 | `benchmarks/e2e/slam/` | 地图构建速度、CPU/内存占用 |
| 感知流水线 | `benchmarks/e2e/perception-pipeline/` | 检测 + 分割流水线端到端帧延迟 |

这三个 benchmark 需要真实硬件（机器人底盘 / 传感器 / 仿真环境），沙箱无法运行。每个目录内的 `README.md` 有详细的前置条件说明。

---

## 9. 结果 JSON Schema

所有 benchmark 必须输出符合 `schema_version = "1"` 的 JSON。最小结构：

```json
{
  "schema_version": "1",
  "benchmark": "system.cpu.sysbench",
  "platform": "orin",
  "timestamp": "2026-04-25T10:00:00Z",
  "env_ref": "env.json",
  "params": { "threads": 8, "duration_s": 30 },
  "metrics": {
    "events_per_sec": {
      "p50": 12345.6,
      "p95": 12500.1,
      "unit": "1/s"
    }
  }
}
```

每个 metric 子对象至少包含 `p50`（或 `avg`）+ `unit`。完整 schema 见 [`docs/result-schema.md`](result-schema.md)。

`collect-results.py` 在归档时会验证所有必填字段，不合规的文件记录到 `index.json` 的 `errors` 数组中。

---

## 10. 典型工作流

### 10.1 首次跑通 + 建立基线

```bash
# 1. 安装依赖
sudo ./scripts/install-deps.sh --ros-distro=humble

# 2. 跑标准套件
./scripts/run-suite.sh --platform=orin --suite=standard --out-dir=results

# 3. 归档
python3 scripts/collect-results.py --platform=orin

# 4. 保存为基线（找到刚才生成的运行目录）
RUNDIR=$(ls -d results/orin/*/  | sort | tail -1)
python3 scripts/regression.py save \
    --run-dir="${RUNDIR%/}" \
    --baseline=baselines/orin.json

echo "基线已保存：baselines/orin.json"
```

---

### 10.2 双平台横向对比

```bash
# 在平台 A 跑
./scripts/run-suite.sh --platform=orin   --suite=standard --out-dir=results
# 在平台 B 跑
./scripts/run-suite.sh --platform=s100   --suite=standard --out-dir=results

# 汇总各自索引
python3 scripts/collect-results.py --platform=orin
python3 scripts/collect-results.py --platform=s100

# 生成对比报告（Markdown + PNG 图表）
RUNDIR_ORIN=$(ls -d results/orin/*/ | sort | tail -1)
RUNDIR_S100=$(ls -d results/s100/*/ | sort | tail -1)

python3 scripts/compare.py \
    --a "${RUNDIR_ORIN%/}" \
    --b "${RUNDIR_S100%/}" \
    --out reports/orin-vs-s100.md \
    --charts

# 或者生成 HTML（自包含，无需 markdown 渲染器）
python3 scripts/compare.py \
    --a "${RUNDIR_ORIN%/}" \
    --b "${RUNDIR_S100%/}" \
    --out reports/orin-vs-s100.html
```

---

### 10.3 CI 回归门禁

将以下步骤加入 CI（参考 `.github/workflows/ci.yml`）：

```bash
# 跑套件
./scripts/run-suite.sh --platform=ci-runner --suite=standard --out-dir=/tmp/results

# 归档
RUNDIR=$(ls -d /tmp/results/ci-runner/*/ | sort | tail -1)
python3 scripts/collect-results.py --platform=ci-runner --results-dir=/tmp/results

# 检测回归（exit 1 = FAIL，exit 2 = WARN）
python3 scripts/regression.py check \
    --run-dir="${RUNDIR%/}" \
    --baseline=baselines/ci-runner.json \
    --warn-pct=5 \
    --fail-pct=15 \
    --out=reports/regression.md
```

> `baselines/ci-runner.json` 需提前用 `regression.py save` 生成并提交到仓库。

---

### 10.4 应用优化前后 A/B 对比

```bash
# 启动被测 ROS 2 进程（例如 slam_node）
ros2 run my_slam slam_node &
SLAM_PID=$!

# 会话 A：优化前
./benchmarks/ros2/app-profiler/profile.sh \
    --pid=${SLAM_PID} \
    --session=before-opt \
    --platform=orin \
    --out-dir=results

# 应用代码优化 / 参数调整后重启进程 ...

# 会话 B：优化后
./benchmarks/ros2/app-profiler/profile.sh \
    --pid=${SLAM_PID} \
    --session=after-opt \
    --platform=orin \
    --out-dir=results

# 生成 A/B 对比 HTML
SESSION_A=$(ls -d results/orin/before-opt_*/ | sort | tail -1)
SESSION_B=$(ls -d results/orin/after-opt_*/ | sort | tail -1)

python3 scripts/compare-app-profile.py \
    --a "${SESSION_A%/}" \
    --b "${SESSION_B%/}" \
    --label-a="before-opt" \
    --label-b="after-opt" \
    --out=reports/slam-opt-ab.html
```

---

## 11. 常见问题 (FAQ)

**Q: 没有安装 sysbench / fio / iperf3，能跑吗？**  
A: 能。所有系统 benchmark 都有 python3 回退（零外部依赖）。回退值是保守下界，仅用于 CI 验证和快速冒烟测试，不适合与真实工具值做趋势比较。`notes` 字段有明确标注。

**Q: `collect-results.py` 报 "no results directory"？**  
A: 检查 `--results-dir` 是否正确，以及 `results/<platform>/<run-id>/` 目录结构是否存在。若手动指定了 `--run-dir` 而没有使用 `env-snapshot.sh`，则目录层级需手动保证。

**Q: `trend.py` 报 "index not found"？**  
A: 需先运行 `python3 scripts/collect-results.py --platform=<id>` 生成 `results/<platform>/index.json`。

**Q: `compare.py` 警告 "skip ... (no 'benchmark' field)"？**  
A: JSON 文件缺少顶层 `benchmark` 字段（schema 必填）。检查 `docs/result-schema.md` 并修正 benchmark 脚本输出。

**Q: `regression.py check` exit 2 是什么意思？**  
A: 有指标超过 `--warn-pct` 但没有超过 `--fail-pct`。在 CI 里通常作 warning 处理而非 block。

**Q: 如何只测试某一个具体 benchmark 而不跑全套？**  
A: 直接调用该 benchmark 的 `run.sh` 并传 `--run-dir`：

```bash
./benchmarks/system/cpu/sysbench/run.sh \
    --platform=orin \
    --run-dir=$(./scripts/env-snapshot.sh --platform=orin)
```

**Q: 如何增加一个新平台？**  
A: 给 `--platform=` 起一个新 id（如 `ascend310`），然后在 `env-snapshot.sh` 的 `case` 块里添加对应的平台特定命令（可以是空）。结果会自动存到 `results/ascend310/`。

---

## 12. 增加新 Benchmark

1. 复制模板目录：

```bash
cp -r templates/benchmark-template/ benchmarks/system/mytest/
```

2. 按 `templates/benchmark-template/README.md` 的指引填空。

3. 关键约定：
   - 脚本接受 `--platform=<id>` 和 `--run-dir=<path>`
   - 输出文件命名 `<benchmark_id>.json`，格式符合 schema v1
   - 脚本有 +x 可执行权限
   - 在 `scripts/run-suite.sh` 的 `standard` 或 `full` 候选列表中注册

4. 运行 `python3 scripts/collect-results.py` 验证输出是否通过 schema 检查（`errors: []`）。

---

## 13. 退出码速查

| 脚本 | 退出码 | 含义 |
|---|---|---|
| `run-suite.sh` | `0` | 全部 benchmark 通过 |
| `run-suite.sh` | 非 `0` | 有 benchmark 失败（`fail` 计数 > 0） |
| `collect-results.py` | `0` | 归档成功，无 schema 错误 |
| `collect-results.py` | `1` | 有 schema 错误 |
| `regression.py check` | `0` | 全部指标 OK / IMPROVE |
| `regression.py check` | `1` | 至少一个 FAIL（超 `--fail-pct`） |
| `regression.py check` | `2` | 至少一个 WARN（超 `--warn-pct`，无 FAIL） |
| `compare.py` | `0` | 报告生成成功 |
| `trend.py` | `0` | HTML 生成成功（无数据时也是 0，输出 WARN） |
| `env-snapshot.sh` | `0` | 快照成功，运行目录路径打印到 stdout |
| `env-snapshot.sh` | `2` | 缺少必要参数 |

---

*本手册随代码同步维护。如发现内容与脚本行为不符，请在 issue 中反馈。*
