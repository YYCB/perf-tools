# 散热与功耗 Cheat Sheet

> 状态：📝 stub。

## 1. 测什么

- **稳态功耗**：满载 5 min 后 3 min 平均
- **峰值功耗**：1 s 滑窗最大
- **能效**：perf / W（用 benchmark 主指标除以平均功耗）
- **温度曲线**：核温、SoC 结温、外壳温度的时间序列
- **降频 (throttle)**：是否触发以及触发后稳态频率

## 2. 平台采集方法

| 平台 | 工具 |
|---|---|
| Jetson | `tegrastats --interval 1000` （含 VDD_IN / GPU / CPU / SoC 各路功耗） |
| x86 Intel | `turbostat`、`powertop --time=60` |
| x86 AMD | `amd_energy` / `zenpower` |
| RK3588 | `cat /sys/class/thermal/thermal_zone*/temp`，电流需外置 INA226 |
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

## TODO

- [ ] tegrastats 解析脚本
- [ ] INA226 采样脚本
- [ ] 跨平台等功耗对比模板
