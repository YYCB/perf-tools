# 统一结果 JSON Schema

所有 benchmark 的输出**必须**符合此 schema，否则 `scripts/collect-results.py` 与 `scripts/compare.py` 无法处理。

当前 `schema_version = "1"`。

## 顶层结构

```json
{
  "schema_version": "1",
  "benchmark": "system.cpu.sysbench",
  "platform": "orin",
  "timestamp": "2026-04-23T17:00:00Z",
  "host": "orin-devkit-01",
  "env_ref": "../env.json",
  "params": {
    "threads": 8,
    "duration_s": 30,
    "extra": "..."
  },
  "metrics": {
    "events_per_sec": {
      "p50": 12345.6,
      "p95": 12500.1,
      "min": 12100.0,
      "max": 12600.0,
      "stdev": 42.0,
      "unit": "1/s"
    },
    "latency_avg_ms": {
      "p50": 0.65,
      "p95": 0.72,
      "stdev": 0.03,
      "unit": "ms"
    }
  },
  "raw_samples": [12340.1, 12345.6, 12350.9, 12348.0, 12349.2],
  "iterations": 5,
  "warmup_s": 5,
  "notes": "MAXN power mode, fan @ 100%"
}
```

## 字段说明

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema_version` | string | ✅ | 当前 `"1"` |
| `benchmark` | string | ✅ | 点分层级 ID，与目录路径对应（如 `system.cpu.sysbench`） |
| `platform` | string | ✅ | 平台标识，与 `--platform` 参数一致（如 `orin` / `s100` / `rk3588` / `x86`） |
| `timestamp` | string | ✅ | ISO 8601 UTC，benchmark 完成时间 |
| `host` | string |   | 主机名（脱敏可选） |
| `env_ref` | string | ✅ | 指向同一目录下 `env.json` 的相对路径 |
| `params` | object | ✅ | 本次运行的输入参数；schema 自由，但同一 benchmark 应保持稳定 |
| `metrics` | object | ✅ | 指标字典；每个 metric 是 `{p50, p95?, p99?, min?, max?, stdev?, avg?, peak?, unit}` 形式 |
| `raw_samples` | array \| object |   | 原始样本，便于后续重新统计 |
| `iterations` | int |   | 重复次数 |
| `warmup_s` | number |   | 预热秒数（已丢弃） |
| `notes` | string |   | 自由备注（电源模式、散热、SDK 版本要点） |

## metric 子对象

至少包含 `p50` 与 `unit`。建议字段：

| key | 含义 |
|---|---|
| `p50` | 中位数（**首选**） |
| `p95`, `p99`, `p99_9` | 高分位 |
| `min`, `max` | 极值 |
| `avg` | 算术平均（次选） |
| `stdev` | 标准差 |
| `peak` | 峰值（功耗常用） |
| `unit` | 字符串单位，如 `"us"`, `"ms"`, `"1/s"`, `"MB/s"`, `"W"` |

## 文件命名约定

每次运行写入：

```
results/<platform>/<YYYY-MM-DD-HHMMSS>/
├── env.json                                  # 由 env-snapshot.sh 生成
├── system.cpu.sysbench.json                  # 一个 benchmark 一个文件
├── system.cpu.sysbench.raw.txt               # 工具原始输出（可选）
└── ...
```

`compare.py` 会跨平台按 `benchmark` 名称匹配并对比。
