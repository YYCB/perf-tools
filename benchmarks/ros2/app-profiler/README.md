# ROS 2 App Profiler

为 ROS 2 应用提供**交互式、非侵入式**的性能数据采集工具。

应用运行时，在后台自动采集：

| 指标 | 来源 |
|---|---|
| CPU 使用率（per-core %） | `/proc/<pid>/stat` |
| 内存 RSS / VSZ | `/proc/<pid>/status` |
| 线程数 | `/proc/<pid>/status` |
| 自愿 / 非自愿上下文切换 | `/proc/<pid>/status` |
| 磁盘 I/O 速率 | `/proc/<pid>/io` |
| 文件描述符数量 | `/proc/<pid>/fd/` |
| 可选：火焰图 SVG | `perf record` + FlameGraph |

采集完成后自动生成**自包含 HTML 报告**，包含时序折线图（vanillaJS/Canvas，无外部依赖）、状态对比表和火焰图。

---

## 目录结构

```
app-profiler/
├── profile.sh      # 用户入口：找进程、启动采集、交互式标记状态、生成报告
├── monitor.py      # 后台采样守护进程（纯 stdlib，无依赖）
├── gen-report.py   # HTML 报告生成器（纯 stdlib，无依赖）
└── README.md       # 本文件
```

---

## 快速上手

### 1. 准备工作

```bash
# 确保目标应用已在运行
ros2 run my_pkg my_node &

# （可选）安装火焰图依赖
sudo apt-get install -y linux-perf
git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
```

### 2. 启动采集

```bash
# 方式 A — 按进程名搜索（最常用）
./benchmarks/ros2/app-profiler/profile.sh \
    --process=my_node \
    --session=feature-ab-test \
    --platform=orin

# 方式 B — 直接指定 PID
./benchmarks/ros2/app-profiler/profile.sh \
    --pid=12345 \
    --session=load-test

# 方式 C — 按 ROS 2 节点名搜索（匹配 cmdline）
./benchmarks/ros2/app-profiler/profile.sh \
    --ros-node=/perception/detector \
    --session=detector-bench \
    --flamegraph          # 同时采集火焰图
```

### 3. 交互式标记状态

工具启动后进入交互提示符，支持以下命令：

```
> m baseline          # 标记"baseline"状态起点
> m feature_on        # 开启你的功能后标记
> m feature_off       # 关闭功能后标记
> s                   # 查看最新一条采样数据
> q                   # 停止采集并生成报告
```

**典型工作流示例：**

```
[✓] Session:  feature-ab-test
[✓] Process:  my_node (PID 12345)
[→] Monitor started

> m baseline            ← 应用空跑，记录基线
  ... （等待 30 秒）
> m feature_on          ← 在另一个终端开启功能
  ... ros2 service call /enable_feature std_srvs/srv/SetBool "{data: true}"
  ... （等待 30 秒）
> m feature_off         ← 关闭功能
  ... ros2 service call /enable_feature std_srvs/srv/SetBool "{data: false}"
  ... （等待 30 秒）
> q                     ← 停止并生成报告
```

### 4. 查看报告

```
[✓] Report: results/orin/feature-ab-test_2026-04-24T10-00-00Z/report.html
```

用浏览器打开该 HTML 文件即可，报告完全自包含，无需网络。

---

## 命令行参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--pid=PID` | 直接指定目标 PID | — |
| `--process=NAME` | 按进程名搜索（`pgrep -f`） | — |
| `--ros-node=NAME` | 按 ROS 2 节点名搜索 cmdline | — |
| `--session=NAME` | 会话名称（用于报告标题和目录名） | 必填 |
| `--platform=ID` | 平台标识符，与其他 benchmark 保持一致 | `hostname` |
| `--interval-ms=N` | 采样间隔（毫秒） | `500` |
| `--out-dir=PATH` | 结果输出根目录 | `<repo>/results` |
| `--flamegraph` | 开启 perf record + 火焰图生成 | 关闭 |
| `--flamegraph-dir=PATH` | FlameGraph 脚本目录 | `~/FlameGraph` |
| `--perf-freq=N` | perf 采样频率（Hz） | `99` |

---

## 输出文件

每次运行在 `results/<platform>/<session>_<timestamp>/` 下生成：

```
results/orin/feature-ab-test_2026-04-24T10-00-00Z/
├── env.json                    # 硬件/内核/ROS 2 环境快照
├── states.jsonl                # 状态标记记录（JSONL）
├── metrics.jsonl               # 时序采样数据（JSONL，每行一条）
├── perf.data                   # perf 原始数据（仅开启 --flamegraph 时）
├── flamegraph.svg              # 火焰图 SVG（仅开启 --flamegraph 时）
├── ros2.app-profiler.json      # 全局统计（符合 docs/result-schema.md v1）
├── report.html                 # 自包含 HTML 报告 ← 主要输出
└── profile.log                 # 工具运行日志（调试用）
```

### metrics.jsonl 字段说明

每行是一个 JSON 对象：

```json
{
  "t":                  1714550400.123,   // Unix 时间戳
  "pid":                12345,
  "cpu_pct":            35.2,             // CPU%（per-core；多线程可超 100%）
  "rss_mb":             245.6,            // 物理内存 RSS（MB）
  "vsz_mb":             1024.0,           // 虚拟内存（MB）
  "threads":            24,               // 线程数
  "vol_ctxt_delta":     12,               // 本采样周期内自愿上下文切换次数
  "nonvol_ctxt_delta":  1,                // 本采样周期内非自愿上下文切换次数
  "io_read_kb":         0.5,              // 本周期磁盘读取量（KB）
  "io_write_kb":        1.2,              // 本周期磁盘写入量（KB）
  "fd_count":           48                // 打开的文件描述符数（可选）
}
```

> **cpu_pct 说明**：数值基于单核心换算。单线程满载 ≈ 100%；4 线程全部满载 ≈ 400%。
> 如需归一化为 0–100%，用 `cpu_pct / nproc`。

---

## HTML 报告内容

| 区块 | 内容 |
|---|---|
| **状态对比表** | 各标记状态的 Avg/p95/Peak CPU%、Avg/Peak RSS、平均线程数、样本数 |
| **CPU 时序图** | CPU% 随时间变化，状态区间用色带标注 |
| **内存时序图** | RSS（MB）随时间变化 |
| **线程数图** | 线程数变化（可观察动态创建/销毁） |
| **上下文切换图** | 自愿上下文切换（每采样周期Δ） |
| **文件描述符图** | FD 数量（可发现 FD 泄漏） |
| **磁盘 I/O 图** | 读/写速率（KB/采样周期） |
| **火焰图** | 嵌入 SVG（仅开启 `--flamegraph` 时） |
| **环境快照** | 内核、CPU governor、ROS 2 发行版、RMW 实现等 |

报告完全自包含，无任何外部 CSS/JS 依赖，可在断网环境中直接打开。

---

## 火焰图使用说明

### 安装依赖

```bash
# perf（Linux 性能分析工具）
sudo apt-get install -y linux-perf

# FlameGraph 脚本（Brendan Gregg）
git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
```

### 权限设置（通常需要）

```bash
# 降低 perf_event_paranoid（重启后失效）
sudo sysctl -w kernel.perf_event_paranoid=1

# 永久生效
echo 'kernel.perf_event_paranoid=1' | sudo tee -a /etc/sysctl.conf
```

### 启用火焰图

```bash
./profile.sh --process=my_node --session=flame-test --flamegraph
# 自动使用 ~/FlameGraph；自定义路径：
./profile.sh --process=my_node --session=flame-test \
    --flamegraph --flamegraph-dir=/opt/FlameGraph
```

### 调试符号（获得有意义的函数名）

```bash
# C++ 节点：编译时加 -g（RelWithDebInfo）
colcon build --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo

# 系统库调试符号
sudo apt-get install -y libc6-dbg libstdc++6-dbgsym
```

---

## 单独运行子脚本

### 只运行 monitor.py（后台采样）

```bash
python3 benchmarks/ros2/app-profiler/monitor.py \
    --pid=12345 \
    --out-dir=/tmp/my-session \
    --interval-ms=200
```

### 只生成报告（对已有会话目录）

```bash
python3 benchmarks/ros2/app-profiler/gen-report.py \
    --session-dir=results/orin/my-session_2026-04-24T10-00-00Z \
    --session-name=my-session \
    --process=my_node \
    --pid=12345 \
    --out=/tmp/report.html
```

---

## 多节点 / 组件容器

ROS 2 组件容器（`component_container`）在一个进程中承载多个节点组件，
直接按进程名搜索即可：

```bash
# 系统组件容器
./profile.sh --process=component_container --session=container-bench

# 自定义容器名称
./profile.sh --process=my_perception_container --session=perception-bench

# 如果有多个同名容器，用 PID 精确指定
ros2 component list   # 先找到对应容器
./profile.sh --pid=<container_pid> --session=container-bench
```

---

## 常见问题

### 采样数据为空
- 检查目标进程是否正在运行：`ps aux | grep <name>`
- 检查权限：`/proc/<pid>/io` 需要与目标进程同用户或 root
- 查看日志：`cat results/<platform>/<session>/profile.log`

### perf 无输出 / 权限错误
```bash
# 检查当前值
cat /proc/sys/kernel/perf_event_paranoid   # >1 则可能被拒绝

# 临时降权
sudo sysctl -w kernel.perf_event_paranoid=1

# 或者以 root 运行 profile.sh
sudo ./profile.sh --process=my_node --session=test --flamegraph
```

### 进程重启后丢失跟踪
`monitor.py` 只跟踪初始 PID。如果进程重启，重新运行 `profile.sh`。
如需跟踪会重启的节点，建议监控其父进程（launch 进程）或使用固定 PID。

### 火焰图只有十六进制地址
节点没有调试符号。重新编译：
```bash
colcon build --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo
```

---

## 与其他工具集成

### 跨会话回归对比（`scripts/compare-app-profile.py`）

最常见的场景：**同一节点开/关某功能** 或 **v1 vs v2** 两个会话之间的回归对比。
该脚本读取两个 session 目录（`metrics.jsonl` + `states.jsonl` + `env.json`），
生成一份**自包含 HTML**，包含：

- **Fairness Statement** — 两侧 `env.json` 关键项对比（kernel / governor / RMW / 域 ID 等），不一致行高亮 ⚠️
- **Global Summary** — CPU / RSS / 线程数 / FD / 上下文切换 的 avg/p50/p95/max 双栏对比 + Δ% + 优劣判定
- **Per-state Comparison** — 自动按状态标签（如 `feature_on` / `feature_off`）对齐，仅两侧都存在的标签会逐项对比；只在一侧出现的标签会单独列出
- **Time-series Overlays** — CPU / RSS / 线程数 / FD / 上下文切换 五张折线图，A 蓝 / B 红，时间轴用各自相对开始时间对齐

```bash
# 两次运行同一节点：基线 vs 开启某功能
python3 scripts/compare-app-profile.py \
    --a results/orin/baseline_2026-04-24T10-00-00Z \
    --b results/orin/feature-on_2026-04-24T11-00-00Z \
    --label-a=baseline --label-b=feature-on \
    --out reports/feature-ab.html

# 跨平台对比同一会话（也可以）
python3 scripts/compare-app-profile.py \
    --a results/orin/load-test_<ts> \
    --b results/s100/load-test_<ts>
```

输出 HTML 完全离线，可直接发邮件 / 上传到 PR。

### 与 scripts/compare.py 集成

每次会话输出的 `ros2.app-profiler.json` 符合统一 schema（`docs/result-schema.md`），
可直接用 `scripts/compare.py` 对比两个平台的同一会话：

```bash
python3 scripts/compare.py \
    --run-a=results/orin/feature-ab-test_2026-04-24/ \
    --run-b=results/s100/feature-ab-test_2026-04-25/ \
    --out=reports/orin-vs-s100-app-profiler.md
```

### 与 scripts/collect-results.py 集成

```bash
python3 scripts/collect-results.py --platform=orin
```

---

*milestone: M1 — 可立即使用；M3 将增加 ROS 2 topic 延迟叠加显示；M4 将增加 CI 自动回归对比。*
