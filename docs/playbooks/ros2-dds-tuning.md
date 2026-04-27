# ROS 2 / DDS 调优 Cheat Sheet

> 配套工具：[`config/cyclonedds.xml`](../../config/cyclonedds.xml)、[`config/fastdds.xml`](../../config/fastdds.xml)

---

## 1. RMW 选型速查

| 场景 | 推荐 RMW | 理由 |
|---|---|---|
| 默认 / 通用 | `rmw_fastrtps_cpp` | ROS 2 默认，兼容性最好 |
| 大消息 / 低延迟 | `rmw_cyclonedds_cpp` | 大 payload 表现稳定，可调参数清晰 |
| 跨网络 / 跨主机 | `rmw_zenoh_cpp` | 路由灵活，发现机制更轻 |
| 安全 (SROS 2) | `rmw_fastrtps_cpp` | 官方安全特性最完善 |
| 实时控制 (< 100 µs) | `rmw_cyclonedds_cpp` | 延迟可调性更好 |

切换方式：

```bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
# 永久写入 ~/.bashrc 或 /etc/environment
```

---

## 2. CycloneDDS 关键参数

使用仓库提供的模板：

```bash
export CYCLONEDDS_URI=file://$(pwd)/config/cyclonedds.xml
```

主要旋钮（见 `config/cyclonedds.xml`）：

| 参数 | 场景 | 推荐值 |
|---|---|---|
| `MaxMessageSize` | 点云 / 图像 (> 64 KB) | `65507B` |
| `FragmentSize` | 同上（网络 MTU 对齐） | `4000B` |
| `SocketReceiveBufferSize` | 高吞吐 | `10MB`（配合内核 rmem_max） |
| `AllowMulticast` | 多节点同主机 | `true`；跨子网隔离时设 `false` |

内核配套：

```bash
# 持久化写入 /etc/sysctl.d/99-ros2-dds.conf
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.rmem_default=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

---

## 3. FastDDS 关键参数

```bash
export FASTRTPS_DEFAULT_PROFILES_FILE=$(pwd)/config/fastdds.xml
```

| 参数 | 大消息（点云 / 图像）| 小消息（控制 / TF） |
|---|---|---|
| `publishMode` | `ASYNCHRONOUS` | `SYNCHRONOUS` |
| `historyMemoryPolicy` | `PREALLOCATED_WITH_REALLOC` | `PREALLOCATED` |
| Shared Memory | 开启（`SHM` transport） | 可选 |

---

## 4. QoS 速查

| 场景 | reliability | durability | history | depth |
|---|---|---|---|---|
| 传感器流（可丢） | `best_effort` | `volatile` | `keep_last` | 5 |
| 控制指令 | `reliable` | `volatile` | `keep_last` | 1 |
| 静态参数 / TF static | `reliable` | `transient_local` | `keep_last` | 1 |
| 图像 / 点云 | `best_effort` | `volatile` | `keep_last` | 1 |
| 诊断 / 日志 | `reliable` | `volatile` | `keep_last` | 10 |

> **注意**：intra-process 通信不支持 `transient_local`，需提前避免。

---

## 5. Intra-process 通信

零复制最大受益场景：同进程内的图像、点云传递（1 MB+）。

```cpp
// C++ 节点
auto options = rclcpp::NodeOptions().use_intra_process_comms(true);
auto node = std::make_shared<MyNode>(options);

// 发布时用 unique_ptr / shared_ptr 才能零复制
auto msg = std::make_unique<sensor_msgs::msg::Image>();
publisher_->publish(std::move(msg));
```

限制：
- Publisher 与 Subscriber 必须在**同一个 executor**。
- `transient_local` durability 会禁用 intra-process。
- Python（rclpy）intra-process 支持有限，建议在 C++ 节点中使用。

量化收益：使用仓库的 intra-process benchmark：

```bash
./benchmarks/ros2/intra-process/run.sh --platform=orin --payloads=1024,1048576
```

---

## 6. DDS 发现调优

大规模部署（节点 > 50）DDS 发现广播会造成 CPU 和网络抖动。

### 禁用多播发现（固定 peer 地址）

CycloneDDS（`config/cyclonedds.xml`）：

```xml
<AllowMulticast>false</AllowMulticast>
<Discovery>
  <Peers>
    <Peer address="192.168.1.100"/>
    <Peer address="192.168.1.101"/>
  </Peers>
</Discovery>
```

### 减少发现周期

```xml
<Internal>
  <ParticipantIndex>auto</ParticipantIndex>
  <MaxAutoParticipantIndex>9</MaxAutoParticipantIndex>
</Internal>
```

---

## 7. 大消息传输优化

对于 1 MB 图像或 1 M 点云（约 12 MB）：

```bash
# 1. 扩大内核 UDP 缓冲区
sudo sysctl -w net.core.rmem_max=134217728   # 128 MB
sudo sysctl -w net.core.wmem_max=134217728

# 2. 使用 Shared Memory transport（同主机最快）
# 在 config/fastdds.xml 中启用 SHM transport

# 3. 禁用 NAGLE (TCP 模式时)
sudo ethtool -K eth0 gro off tso off

# 4. 降低 QoS history depth
# 大消息用 depth=1 避免队列积压
```

量化不同 payload 的延迟：

```bash
./benchmarks/ros2/pubsub-latency/run.sh \
  --platform=orin \
  --payloads=1024,65536,1048576 \
  --qos-pairs=reliable+volatile,best_effort+volatile
```

---

## 8. 常见问题排查

| 现象 | 可能原因 | 解决方案 |
|---|---|---|
| 发布延迟突增（spikes） | DDS 线程抢占 / 缺 UDP 缓冲 | 增大 `SocketReceiveBufferSize`；`chrt -f` 提优先级 |
| 节点间通信丢包 | UDP 缓冲溢出 | 调大 `rmem_max`；降低发布频率 |
| 跨主机发现慢 | 多播被交换机过滤 | 改用 unicast peer 模式 |
| intra-process 无效果 | executor 不同 / durability 不对 | 检查 `use_intra_process_comms` 及 QoS |
| 图像延迟高 | 序列化 + 拷贝 | SHM transport + intra-process + zero-copy publisher |
| ROS_DOMAIN_ID 冲突 | 多套系统共用网络 | 为每套机器人分配独立 DOMAIN_ID |

