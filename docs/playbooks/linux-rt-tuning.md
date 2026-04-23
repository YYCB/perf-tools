# Linux 实时性调优 Cheat Sheet

> 状态：📝 stub。

## 1. 选内核

| 选项 | 何时用 |
|---|---|
| 标准内核 | 一般感知 / 规划任务，能容忍 ms 级抖动 |
| `PREEMPT` | 折中，无需打 RT 补丁 |
| `PREEMPT_RT` | 控制环 / 安全相关，需要 µs 级最坏延迟 |

Jetson 自带 PREEMPT_RT 镜像（JetPack 提供）；Horizon RDK 视版本而定。

## 2. CPU 隔离

GRUB 启动参数：

```
isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7
```

把控制环线程钉到隔离核：

```bash
chrt -f 80 taskset -c 4 ./control_node
```

## 3. IRQ 亲和性

```bash
# 把所有 IRQ 移到 cpu0-3
for i in /proc/irq/*/smp_affinity_list; do echo "0-3" | sudo tee "$i"; done
# 关闭 irqbalance
sudo systemctl disable --now irqbalance
```

## 4. cyclictest 测最坏延迟

```bash
sudo cyclictest -m -p 80 -i 200 -h 1000 -D 1h --quiet
```

报告：max latency、p99 latency、直方图。

## 5. 频率与电源

```bash
# 锁定 performance governor
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$c"
done
```

Jetson：`sudo nvpmodel -m 0 && sudo jetson_clocks`。

## 6. 关后台

- `systemctl disable --now snapd unattended-upgrades cron`（评估业务影响后）
- 桌面环境：用 multi-user.target 而不是 graphical.target

## TODO

- [ ] PREEMPT_RT 安装步骤（按平台）
- [ ] perf / ftrace 抖动定位脚本
