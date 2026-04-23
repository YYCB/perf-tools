# 案例研究：Jetson AGX Orin → 地瓜 S100 平台量化对比

> 状态：📝 模板 — 实测数据待 M2 完成。本文档既是工作流说明，也是后续报告的填空模板。

## 0. 为什么做这件事

具身智能产品在选型 / 迁移阶段（如从 Jetson AGX Orin 迁到地瓜 S100），需要回答三类问题：

1. **能不能换** —— 端到端任务延迟 / 吞吐是否仍达标？
2. **换了之后哪里慢** —— 是 CPU、内存带宽、NPU、还是 ROS 2 通信？
3. **每瓦性能如何** —— 同等功耗下谁更优？

本案例给出一条**端到端可复现**的路径。

---

## Step 1 — 环境对齐

| 项 | Orin | S100 |
|---|---|---|
| OS | Ubuntu 22.04 | Ubuntu 22.04 (RDK OS) |
| Kernel | （由 env-snapshot 填） | （由 env-snapshot 填） |
| ROS 2 | Humble | Humble |
| RMW | `rmw_cyclonedds_cpp` | `rmw_cyclonedds_cpp` |
| 电源模式 | MAXN | 厂家最高功耗档 |
| 等功耗对比档 | 30 W | 30 W（若可设） |
| 散热 | 同型号风扇 100%，室温 25°C | 同型号风扇 100%，室温 25°C |

> 所有不同项必须用 ⚠️ 标出（参见 `docs/methodology.md` §6）。

---

## Step 2 — 跑分层套件

```bash
# 在 Orin 上
./scripts/env-snapshot.sh --platform=orin
./scripts/run-suite.sh --platform=orin --suite=full

# 在 S100 上
./scripts/env-snapshot.sh --platform=s100
./scripts/run-suite.sh --platform=s100 --suite=full
```

`--suite=full` 包含：

1. **硬件底座**：CPU (sysbench, stress-ng) / 内存 (stream, mbw) / 存储 (fio) / 网络 (iperf3, sockperf) / GPU (clpeak) / NPU（厂家工具封装）
2. **系统实时性**：cyclictest 1 小时
3. **ROS 2 中间件**：performance_test
   - payload: 1 KB / 64 KB / 1 MB
   - QoS: best_effort+volatile, reliable+volatile
   - RMW: fastrtps, cyclonedds（条件允许时再加 zenoh）
4. **端到端**：固定 rosbag 回放 → 同一感知模型推理 → 测 sensor → /detection 端到端延迟与吞吐
5. **功耗曲线**：满载 / 典型负载下 W 与 °C 时间序列

---

## Step 3 — 生成对比报告

```bash
python3 scripts/compare.py \
    --a results/orin/<date> \
    --b results/s100/<date> \
    --out reports/orin-vs-s100-<yyyymm>.md
```

报告自动生成内容：

- **对比表**：每项指标 A / B / 绝对差 / 百分比差 / perf-per-W 差
- **公平性声明**：直接读两份 env.json
- **图**（M2 接 matplotlib）：雷达图、时序对比图、能效曲线

---

## Step 4 — 解读模板

### 4.1 瓶颈分类

填表（示例）：

| 指标 | A vs B | 推断瓶颈层 | 行动 |
|---|---|---|---|
| sysbench multi-thread | -10% | 硬件（核数 / 频率） | 接受 |
| memcpy 1MB | -25% | 内存带宽 | 评估是否致命 |
| ROS 2 1MB pubsub p99 | +50% | DDS 配置 | 调 DDS 参数（见 playbook） |
| 感知模型 FPS | -30% | NPU 算子覆盖 | 量化 / 改算子 |
| 控制环 jitter | 持平 | OK | — |

### 4.2 迁移建议清单（示例占位）

- [ ] 模型从 FP16 (TensorRT) 量化到 INT8 (HBDK)，重新评估精度
- [ ] DDS 大消息走 SHM transport
- [ ] 控制环线程绑核 + RT 优先级
- [ ] 散热重新设计（S100 在 50 W 档若 5 min 内降频，需要更强散热）

---

## Step 5 — 收益（对外汇报口径）

1. **采购 / 选型决策**：用数据回答"换平台值不值"
2. **回归保护**：以后 SDK 升级，重跑一遍立刻发现性能退化
3. **瓶颈定位**：分层数据让你知道该优化硬件、内核还是应用层
4. **对外输出**：报告可以直接发给客户 / 老板 / 上下游硬件厂商
5. **议价能力**：和地瓜 / 英伟达谈判时有量化论据
6. **个人品牌**：长期沉淀就是行业内独一无二的实测数据库
