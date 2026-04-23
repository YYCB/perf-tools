# ROS 2 / DDS 调优 Cheat Sheet

> 状态：📝 stub，逐步补充实战经验。

## 1. RMW 选型速查

| 场景 | 推荐 RMW | 理由 |
|---|---|---|
| 默认 | `rmw_fastrtps_cpp` | ROS 2 默认，兼容性最好 |
| 大消息 / 低延迟 | `rmw_cyclonedds_cpp` | 大 payload 表现稳定，可调参数清晰 |
| 跨网络 / 跨主机 | `rmw_zenoh_cpp` | 路由灵活，发现机制更轻 |
| 安全 (SROS 2) | `rmw_fastrtps_cpp` | 官方安全特性最完善 |

切换：

```bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

## 2. CycloneDDS 关键参数

`/etc/cyclonedds.xml`（指向 `CYCLONEDDS_URI`）：

```xml
<CycloneDDS>
  <Domain id="any">
    <General>
      <NetworkInterfaceAddress>auto</NetworkInterfaceAddress>
      <AllowMulticast>true</AllowMulticast>
      <MaxMessageSize>65500B</MaxMessageSize>
      <FragmentSize>4000B</FragmentSize>
    </General>
    <Internal>
      <SocketReceiveBufferSize min="10MB"/>
      <SocketSendBufferSize min="10MB"/>
    </Internal>
  </Domain>
</CycloneDDS>
```

配合内核：

```bash
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.rmem_default=26214400
```

## 3. FastDDS 关键参数

参考 `fastdds.xml`，重点：`udp.max_message_size`、`asynchronous` 发布、SHM transport。

## 4. QoS 速查

| 场景 | reliability | durability | history | depth |
|---|---|---|---|---|
| 传感器流（可丢） | best_effort | volatile | keep_last | 5 |
| 控制指令 | reliable | volatile | keep_last | 1 |
| 静态参数 / TF static | reliable | transient_local | keep_last | 1 |

## 5. Intra-process

- 对同进程节点用 `IntraProcessSetting::Enable`，可省掉序列化和 socket，对大消息（图像 / 点云）收益最大
- 注意：必须用 `rclcpp::NodeOptions().use_intra_process_comms(true)`，且 publisher 与 subscriber 都不能用 `transient_local`

## TODO

- [ ] 各 RMW 在 1KB / 64KB / 1MB payload 下的 latency 对比图
- [ ] DDS discovery 风暴诊断
- [ ] ROS 2 Jazzy 与 Humble 差异
