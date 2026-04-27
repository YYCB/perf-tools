# Linux 实时性调优 Cheat Sheet

> 适用于：Jetson AGX Orin (JetPack)、RK3588、x86 Ubuntu 22.04

---

## 1. 选内核

| 选项 | 延迟量级 | 何时用 |
|---|---|---|
| 标准内核 | 1–10 ms | 一般感知/规划，能容忍 ms 级抖动 |
| `PREEMPT` | 100 µs–1 ms | 折中，无需打 RT 补丁 |
| `PREEMPT_RT` | 10–100 µs | 控制环/安全相关，需要 µs 级最坏延迟 |

Jetson 自带 PREEMPT_RT 镜像（JetPack 6.x 提供，`sudo apt install linux-headers-*-rt`）；
RK3588 视 SDK 版本而定，可自行打 PREEMPT_RT 补丁编译。

验证当前内核抢占级别：

```bash
uname -v | grep -i 'preempt'
cat /sys/kernel/debug/preempt || zcat /proc/config.gz | grep CONFIG_PREEMPT
```

---

## 2. CPU 隔离

在 `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT` 中添加：

```
isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7
```

然后 `sudo update-grub && sudo reboot`。

将控制环线程钉到隔离核、提升调度优先级：

```bash
# 钉 CPU + FIFO 优先级 80（最高可用 99）
chrt -f 80 taskset -c 4 ./control_node

# 或对已运行进程
PID=$(pgrep my_ros_node)
taskset -cp 4 ${PID}
chrt -f -p 80 ${PID}
```

检查哪些进程还在竞争隔离核：

```bash
ps -eo pid,psr,comm | awk '$2>=4 && $2<=7'
```

---

## 3. IRQ 亲和性

把网卡、存储中断移离控制环核：

```bash
# 查看 IRQ 分布
cat /proc/interrupts

# 将 IRQ 100 绑到 CPU 0–3
echo "f" > /proc/irq/100/smp_affinity   # 0xF = CPU 0-3
```

或用 `irqbalance` 自动均衡（关闭 RT 场景下的 IRQ 往隔离核漂移）：

```bash
# /etc/default/irqbalance
IRQBALANCE_BANNED_CPUS="f0"   # CPU 4-7 禁止 IRQ（二进制反序）
sudo systemctl restart irqbalance
```

---

## 4. 内存锁定与巨页

```bash
# 防止 RT 进程页面换出
ulimit -l unlimited        # 或在 systemd service 中 LimitMEMLOCK=infinity
mlockall(MCL_CURRENT | MCL_FUTURE)   # 在代码中调用

# Transparent Huge Pages 对 RT 有害（延迟尖峰）
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

---

## 5. CPU 频率锁定

```bash
# 锁定 performance governor（所有核）
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "${cpu}"
done

# Jetson：同时用 nvpmodel + jetson_clocks
sudo nvpmodel -m 0          # MAXN 功耗模式
sudo jetson_clocks           # 锁到最高频率

# 验证
cpupower frequency-info | grep "current CPU frequency"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
```

---

## 6. 网络实时化（DDS 场景）

```bash
# 禁用 GRO/TSO（降低接收批处理延迟）
sudo ethtool -K eth0 gro off tso off gso off

# 增大套接字缓冲区（避免 DDS 丢包）
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.rmem_default=26214400
sudo sysctl -w net.core.wmem_max=26214400

# 持久化
echo "net.core.rmem_max=26214400" | sudo tee -a /etc/sysctl.d/99-ros2-rt.conf
sudo sysctl --system
```

---

## 7. 测量工具

| 工具 | 用途 | 命令示例 |
|---|---|---|
| `cyclictest` | 调度延迟直方图 | `cyclictest -l 100000 -m -Sp80 -i200 -h400 -q` |
| `rteval` | 完整 RT 评估套件 | `sudo rteval --duration=60` |
| `hwlatdetect` | 硬件/SMI 延迟检测 | `sudo hwlatdetect --duration=60` |
| `perf sched latency` | 调度器事件分析 | `perf sched record; perf sched latency` |
| `ftrace / tracepoint` | 内核函数延迟跟踪 | `trace-cmd record -e irq_handler_entry` |

```bash
# 安装
sudo apt-get install -y rt-tests hwloc numactl
```

---

## 8. 验收标准（参考值）

| 场景 | 最坏延迟目标 | 测量方法 |
|---|---|---|
| 导航控制环 50 Hz | < 1 ms p99 | cyclictest -p80 -i20000 |
| 安全功能链 | < 500 µs p999 | cyclictest -p99 -i1000 |
| 机械臂伺服 1 kHz | < 200 µs p99 | cyclictest -p99 -i1000 |

