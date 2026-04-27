# 散热与功耗 Cheat Sheet

> 适用于：Jetson AGX Orin、Horizon S100、RK3588、x86

---

## 1. 测什么

| 指标 | 含义 | 采集频率 |
|---|---|---|
| **稳态功耗** | 满载 5 min 后 3 min 平均值 | 1 Hz |
| **峰值功耗** | 1 s 滑窗最大值 | 10 Hz |
| **能效 (perf/W)** | benchmark 主指标 / 平均功耗 | — |
| **温度曲线** | 核温、SoC 结温、外壳温度 | 1 Hz |
| **降频 (throttle)** | 是否触发、触发后稳态频率 | 1 Hz |
| **功耗模式** | MAXN / 15 W 等 | once |

---

## 2. 平台采集方法

### Jetson AGX Orin (tegrastats)

```bash
# 每秒采样一次，输出到文件
sudo tegrastats --interval 1000 --logfile /tmp/tegrastats.log &
TS_PID=$!

# 跑你的 benchmark...
./scripts/run-suite.sh --platform=orin --suite=standard

# 停止采样
kill ${TS_PID}

# 解析关键字段：VDD_IN = 总输入功耗
grep "VDD_IN" /tmp/tegrastats.log | head -5

# 快速汇总 (Python)
python3 - << 'PY'
import re, statistics
vals = []
with open('/tmp/tegrastats.log') as f:
    for line in f:
        m = re.search(r'VDD_IN (\d+)mW', line)
        if m:
            vals.append(int(m.group(1)) / 1000.0)  # mW → W
if vals:
    print(f"avg={statistics.fmean(vals):.1f}W  p95={sorted(vals)[int(len(vals)*0.95)]:.1f}W  peak={max(vals):.1f}W")
PY
```

### x86 Intel (turbostat)

```bash
sudo turbostat --interval 1 --show PkgWatt,CoreTmp,Avg_MHz 2>&1 | tee /tmp/turbostat.log &
# ... run benchmark ...
kill %1

# Parse average package power
awk '/^-/{next} NR>1 {sum+=$2; n++} END{print "avg package power:", sum/n, "W"}' /tmp/turbostat.log
```

### x86 AMD (amd_energy / zenpower)

```bash
# Install zenpower kernel module: https://github.com/Ta180m/zenpower3
# or use RAPL via perf:
sudo perf stat -e power/energy-pkg/ sleep 60
```

### RK3588 (thermal sysfs)

```bash
# Temperature (no built-in power measurement; use INA226 or USB power meter)
watch -n1 "paste \
  <(cat /sys/class/thermal/thermal_zone*/type) \
  <(awk '{print \$1/1000 \"°C\"}' /sys/class/thermal/thermal_zone*/temp)"
```

### Generic Linux (powerstat)

```bash
sudo apt-get install -y powerstat
sudo powerstat -R 1 60   # 1 Hz, 60 seconds
```

---

## 3. 自动化采集 (power-thermal benchmark)

```bash
# Platform-aware sampling under CPU load
./benchmarks/system/power-thermal/run.sh \
    --platform=orin \
    --duration=300 \
    --interval=5

# View result
cat results/orin/<run-id>/system.power_thermal.json
```

---

## 4. 降频检测

### Jetson

```bash
# 开启前先锁频
sudo nvpmodel -m 0   # MAXN
sudo jetson_clocks

# 检查是否有 throttle 事件
grep -i throttl /tmp/tegrastats.log | head -10
```

### x86

```bash
# turbostat 中 Bzy_MHz << CPU_max 说明降频
turbostat --show CoreTmp,Bzy_MHz,PkgWatt --interval 2
```

---

## 5. 能效计算

`compare.py` 自动计算 perf/W（当结果中有 `power_w` 字段时）：

```bash
python3 scripts/compare.py \
    --a results/orin/<run1> \
    --b results/s100/<run2> \
    --out reports/energy-efficiency.md --charts
```

手动计算：

```python
# perf/W for higher-is-better metric (e.g. events/s)
perf_per_watt = events_per_sec_p50 / avg_power_w
```

---

## 6. 报告必填字段

每次功耗测试 `env.json` 必须包含：

| 字段 | 来源 |
|---|---|
| `power_mode` | `nvpmodel -q` / `cat /etc/nvpmodel.conf` |
| `thermal_zone_*` | `/sys/class/thermal/*/temp` |
| `fan_speed` | `tegrastats` / 风扇驱动 sysfs |
| `ambient_temp_c` | 外置温度计（可选；记录测试室温） |

`env-snapshot.sh` 已自动采集以上字段（Jetson 使用 tegrastats，其他平台使用 sysfs）。

| Horizon | RDK OS 自带工具；外置 INA226 更准 |
| 通用兜底 | INA226 / INA3221 + I²C → 自研 Python 脚本 |

## 3. 散热条件标定

测试报告必须声明：

- 散热方式：被动 / 风扇型号 + 转速 / 水冷
- 室温（温度计实测，±1°C）
- 机箱开放 / 封闭
- 测试时长（短跑分 vs 长稳态结论会差很多）

## 4. 推荐脚本（待实现）

```bash
benchmarks/system/power-thermal/run.sh \
    --duration=600 \
    --workload=stress-ng \
    --output=power.json
```

输出包括：
- `power_w.avg / peak`
- `temp_c.max`（按 thermal zone 分）
- `freq_throttle_events`（次数 + 总时长）
- 时间序列 CSV

## 7. tegrastats 快速解析

```python
#!/usr/bin/env python3
"""Parse tegrastats log and print power/temp summary.
Usage: python3 parse_tegrastats.py /tmp/tegrastats.log
"""
import re, sys, statistics

lines = open(sys.argv[1]).readlines()
vdd_in, cpu_temps = [], []
for line in lines:
    m = re.search(r'VDD_IN (\d+)mW', line)
    if m: vdd_in.append(int(m.group(1)) / 1000.0)
    m = re.search(r'cpu@(\d+)', line)
    if m: cpu_temps.append(int(m.group(1)))

if vdd_in:
    p = sorted(vdd_in)
    print(f"VDD_IN: avg={statistics.fmean(vdd_in):.1f}W  "
          f"p95={p[int(len(p)*.95)]:.1f}W  peak={max(vdd_in):.1f}W")
if cpu_temps:
    print(f"CPU temp: avg={statistics.fmean(cpu_temps):.0f}°C  max={max(cpu_temps)}°C")
```

## 8. INA226 外置功率计采集（RK3588 等无内置功率传感器的平台）

RK3588 等平台无法从软件读取功耗，需外置 INA226 电流传感器（常见于开发板评估套件）：

```bash
# 读取 INA226 的 sysfs 接口（路径因板卡而异）
cat /sys/bus/i2c/drivers/ina226/*/power    # µW
cat /sys/bus/i2c/drivers/ina226/*/in_voltage0_input   # mV

# 采样脚本（1 Hz）
while true; do
  POWER=$(cat /sys/bus/i2c/drivers/ina226/*/power 2>/dev/null | head -1)
  [[ -n "${POWER}" ]] && echo "$(date +%s) $((POWER / 1000000)) W"
  sleep 1
done | tee /tmp/ina226.log
```

## 9. 跨平台等功耗对比

对比不同平台在相同功耗预算下的性能：

```bash
# Orin @ 30W  vs  S100 @ 30W
# 1. 设置各平台功耗上限
sudo nvpmodel -m 2  # Orin 30W 模式

# 2. 跑标准套件
./scripts/run-suite.sh --platform=orin-30w --suite=standard

# 3. 对比报告（含 perf/W 列）
python3 scripts/compare.py \
    --a results/orin-30w/<run> \
    --b results/s100-30w/<run> \
    --out reports/orin-vs-s100-30w.html
```

`compare.py` 在结果 JSON 中有 `power_w` 字段时自动计算 perf/W 列。

