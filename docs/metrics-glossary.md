# 指标词典 (Metrics Glossary)

跨 benchmark 通用的术语和单位约定，新写脚本前请对齐。

## 通用统计

| 术语 | 含义 | 备注 |
|---|---|---|
| **p50 / median** | 50% 分位数 | 比 mean 更抗离群值，**首选指标** |
| **p95 / p99 / p99.9** | 95/99/99.9% 分位数 | 用于刻画长尾，实时系统重点关注 |
| **stdev** | 样本标准差 | 用于刻画稳定性 |
| **CoV** | 变异系数 = stdev / mean | 跨量纲比较稳定性，越小越稳 |
| **min / max** | 最小 / 最大值 | 仅供参考，不作为主结论 |
| **trimmed mean** | 截尾均值（去掉前后 5%） | 介于 mean 和 median 之间 |

> 报结果时**永远**给出至少 `p50 + p95 + stdev` 三件套。

## 延迟 / 时延

| 术语 | 含义 |
|---|---|
| **latency** | 单次操作从发起到完成的时间，单位 µs / ms |
| **jitter** | 延迟的波动；常用 max-min、stdev 或 p99-p50 表达 |
| **end-to-end latency** | 端到端延迟，例如 sensor 时间戳 → /detection 发布时间戳 |
| **wakeup latency** | 调度唤醒延迟（cyclictest） |

## 吞吐 / 速率

| 术语 | 含义 |
|---|---|
| **throughput** | 单位时间完成量，单位与 benchmark 相关（events/s, MB/s, msg/s） |
| **goodput** | 有效吞吐，扣除重传 / 协议开销 |
| **FPS** | Frames per second，相机 / 推理流水线常用 |
| **IOPS** | I/O Operations per second（fio） |
| **bandwidth** | 带宽，单位 MB/s 或 Gb/s（注意大小写） |

## 算力 / 利用率

| 术语 | 含义 |
|---|---|
| **GFLOPS / TFLOPS** | 每秒浮点运算次数（10⁹ / 10¹²） |
| **TOPS** | 每秒整数运算次数，常用于 NPU（多为 INT8） |
| **TOPS 利用率** | 实测 TOPS / 标称 TOPS，反映模型/runtime 能否吃满硬件 |
| **CPU%** | `top` 口径，单核 100% = 一个核满载 |
| **GPU util** | nvidia-smi / tegrastats 口径，注意 SM 利用率 ≠ 显存带宽利用率 |

## 功耗 / 散热

| 术语 | 含义 |
|---|---|
| **W (avg / peak)** | 功耗，分平均与峰值；电池系统需算积分 (Wh) |
| **perf/W** | 性能每瓦，跨平台公平对比的关键指标 |
| **junction temp / Tj** | 芯片结温 |
| **throttle** | 降频；记录是否触发以及触发阈值 |

## ROS 2 / DDS

| 术语 | 含义 |
|---|---|
| **RMW** | ROS 2 中间件抽象层（rmw_fastrtps_cpp / rmw_cyclonedds_cpp / rmw_zenoh_cpp） |
| **QoS** | Quality of Service：reliability、durability、history、depth 等 |
| **intra-process** | 同进程内零拷贝传输 |
| **discovery time** | 节点 / 话题发现延迟 |
| **lost / late samples** | 丢包 / 迟到包数量 |

## 实时性

| 术语 | 含义 |
|---|---|
| **scheduling latency** | 任务从 ready 到实际运行的延迟 |
| **WCET** | Worst-Case Execution Time |
| **deadline miss rate** | 超时率 |

## 单位约定

- 时间：µs / ms / s（不要混用，除非显式标注）
- 字节：**KiB / MiB / GiB**（1024 进制）；网络带宽用 **kb/s / Mb/s / Gb/s**（1000 进制，小写 b = bit）
- 频率：MHz / GHz
- 温度：°C
- 功率：W（毫瓦写 mW）

## JSON metrics 字段约定

```json
"metrics": {
  "latency_us": { "p50": 120.0, "p95": 180.0, "p99": 250.0, "stdev": 15.0, "unit": "us" },
  "throughput":  { "p50": 2048.0, "stdev": 30.0, "unit": "msg/s" },
  "power_w":     { "avg": 25.4, "peak": 31.2, "unit": "W" }
}
```

字段名一律 `snake_case`，单位用 `unit` 显式给出，**不要**把单位编进字段名（除非是约定俗成的 `latency_us`）。
