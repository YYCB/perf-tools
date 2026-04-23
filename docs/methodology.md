# 基准测试方法论 (Methodology)

> "If you can't reproduce it, it's not a measurement — it's an anecdote."

本仓库所有 benchmark **必须**遵守下述规则。否则结果不可比对，不能进入 `results/`。

---

## 1. 环境快照（必须）

每次跑测前先调用：

```bash
./scripts/env-snapshot.sh --platform=<id>
```

它会写入 `results/<platform>/<YYYY-MM-DD-HHMMSS>/env.json`，包含：

- 硬件：`/proc/cpuinfo` 摘要、`lscpu`、`/proc/meminfo`、`lspci`/`lsusb`、磁盘型号、网卡型号
- 内核 / 发行版：`uname -a`、`/etc/os-release`
- CPU 状态：governor、当前频率、最大频率
- 温度：`/sys/class/thermal/thermal_zone*/temp`
- 电源模式：Jetson 上的 `nvpmodel -q`、`jetson_clocks --show`；其他平台对应工具
- ROS 2：`ROS_DISTRO`、`RMW_IMPLEMENTATION`、`ROS_DOMAIN_ID`，DDS 配置文件路径
- 容器：是否在容器内、镜像 tag

**报告里的差异声明必须基于此 env.json**。

## 2. 预热 (Warm-up)

- 跑测前先空跑 ≥ 30 s 满载（如 `stress-ng --cpu $(nproc) -t 30s`），让频率/温度进入稳态
- benchmark 自身丢弃前 N 秒数据（默认 5 s 或前 10% 样本）
- 长时间任务（cyclictest / 功耗曲线）允许冷启动数据，但报告时单独标注

## 3. 多次重复 + 统计

- 每个 case 至少 **5 次**独立运行
- 输出 **中位数 (p50) + p95 + 标准差**，**不要**只报峰值或单次结果
- 跑分越短的项目重复次数越高（例如内存延迟测 ≥ 20 次）
- 离群值剔除：基于 IQR 1.5× 规则，或保守地保留全部样本但分别给出 raw / trimmed 两组

## 4. 隔离 (Isolation)

- **CPU 亲和性**：用 `taskset` / `chrt` 把测试进程钉在固定核（同 SoC 大/小核分别测）
- **后台进程**：禁用 `snapd`、`unattended-upgrades`、桌面环境；记录 `systemctl list-units --state=running` 到 env.json
- **频率策略**：固定 governor 为 `performance`（用于跑分）或 `powersave`（用于能效对比），并在结果里标注
- **散热**：相同风扇 / 同室温（±2°C），benchmark 开始前温度回到基线
- **网络测试**：直连双机或同 switch 同 VLAN，关闭 offload 时显式声明

## 5. 结果格式统一

所有脚本输出符合 [`result-schema.md`](result-schema.md) 的 JSON。最低字段：

```json
{
  "schema_version": "1",
  "benchmark": "system.cpu.sysbench",
  "platform": "orin",
  "timestamp": "2026-04-23T17:00:00Z",
  "env_ref": "../env.json",
  "params": { "threads": 8, "duration_s": 30 },
  "metrics": {
    "events_per_sec": { "p50": 12345.6, "p95": 12500.1, "stdev": 42.0, "unit": "1/s" }
  },
  "raw_samples": [ ... ],
  "notes": ""
}
```

## 6. 公平性声明 (Fairness Statement)

每份对比报告开头必须列出：

| 项 | 平台 A | 平台 B |
|---|---|---|
| SoC / 内存 / 存储 | … | … |
| 内核 / 发行版 | … | … |
| 电源模式 | MAXN | 最高功耗档 |
| 散热条件 | 风扇 X，25°C | 风扇 X，25°C |
| ROS 2 distro / RMW | Humble / cyclonedds | Humble / cyclonedds |
| SDK 版本 | JetPack 6.0 | RDK OS 3.0.x |
| 测试日期 | 2026-04-23 | 2026-04-23 |

任何**不同**项必须用 ⚠️ 标出，并在解读章节说明对结论的影响。

## 7. 反模式（一票否决）

- ❌ 单次跑分就下结论
- ❌ 不同电源模式 / 散热条件下直接对比
- ❌ 不同 SDK / 驱动版本横向对比却不声明
- ❌ 把 benchmark 跑在桌面环境 + Chrome 后台开着
- ❌ 报最大值不报中位数
- ❌ 把 raw 数据丢掉只留汇总

---

参考：
- LWN, "Reproducible benchmarking" series
- "Systems Benchmarking" (Brendan Gregg, 2020)
- ROS 2 `performance_test` documentation, Apex.AI
