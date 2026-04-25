#!/usr/bin/env python3
"""
latency_probe.py — ROS 2 pub/sub round-trip latency probe.

Two nodes share a MultiThreadedExecutor in the same process:

  pinger  publishes UInt8MultiArray on /perf/ping, subscribes /perf/pong
  ponger  subscribes /perf/ping, immediately republishes on /perf/pong

The first 8 bytes of every message carry a little-endian uint64 send-timestamp
(nanoseconds from time.monotonic_ns).  The pinger measures wall-clock RTT and
reports RTT/2 as a proxy for one-way latency.

Output: one float per line (latency in microseconds) written to stdout.

Usage:
    python3 latency_probe.py \\
        --payload-bytes 1024 \\
        --qos-reliability reliable \\
        --qos-durability volatile \\
        --count 500 \\
        --warmup 50 \\
        --rate-hz 100
"""
from __future__ import annotations

import argparse
import struct
import threading
import time
import sys

import rclpy
from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
from rclpy.qos import (
    QoSProfile,
    ReliabilityPolicy,
    DurabilityPolicy,
    HistoryPolicy,
)
from std_msgs.msg import UInt8MultiArray

HEADER_BYTES = 8  # size of the uint64 LE timestamp


def _make_qos(reliability: str, durability: str, depth: int = 10) -> QoSProfile:
    rel = (
        ReliabilityPolicy.BEST_EFFORT
        if reliability == "best_effort"
        else ReliabilityPolicy.RELIABLE
    )
    dur = (
        DurabilityPolicy.VOLATILE
        if durability == "volatile"
        else DurabilityPolicy.TRANSIENT_LOCAL
    )
    return QoSProfile(
        reliability=rel,
        durability=dur,
        history=HistoryPolicy.KEEP_LAST,
        depth=depth,
    )


class Ponger(Node):
    """Echo node: receive on /perf/ping, republish on /perf/pong unchanged."""

    def __init__(self, qos: QoSProfile) -> None:
        super().__init__("perf_ponger")
        self._pub = self.create_publisher(UInt8MultiArray, "/perf/pong", qos)
        self._sub = self.create_subscription(
            UInt8MultiArray, "/perf/ping", self._cb, qos
        )

    def _cb(self, msg: UInt8MultiArray) -> None:
        self._pub.publish(msg)


class Pinger(Node):
    """Ping node: send timestamped message, wait for pong, measure RTT."""

    def __init__(self, qos: QoSProfile, payload_bytes: int) -> None:
        super().__init__("perf_pinger")
        self._pub = self.create_publisher(UInt8MultiArray, "/perf/ping", qos)
        self._sub = self.create_subscription(
            UInt8MultiArray, "/perf/pong", self._pong_cb, qos
        )
        padded = max(payload_bytes, HEADER_BYTES)
        self._padding = b"\x00" * (padded - HEADER_BYTES)
        self._event = threading.Event()
        self._rtt_ns: int | None = None

    def send_ping(self) -> float | None:
        """Send one ping; return one-way latency in microseconds or None on timeout."""
        self._event.clear()
        self._rtt_ns = None
        send_ns = time.monotonic_ns()
        data = list(struct.pack("<Q", send_ns) + self._padding)
        msg = UInt8MultiArray()
        msg.data = data
        self._pub.publish(msg)
        if self._event.wait(timeout=2.0) and self._rtt_ns is not None:
            return self._rtt_ns / 2_000.0  # ns → µs, halved for one-way estimate
        return None

    def _pong_cb(self, msg: UInt8MultiArray) -> None:
        recv_ns = time.monotonic_ns()
        raw = bytes(msg.data)
        if len(raw) < HEADER_BYTES:
            return
        send_ns = struct.unpack("<Q", raw[:HEADER_BYTES])[0]
        self._rtt_ns = recv_ns - send_ns
        self._event.set()


def main() -> int:
    ap = argparse.ArgumentParser(description="ROS 2 pub/sub latency probe")
    ap.add_argument("--payload-bytes", type=int, default=1024,
                    help="total message size in bytes (min 8)")
    ap.add_argument("--qos-reliability", default="reliable",
                    choices=["reliable", "best_effort"])
    ap.add_argument("--qos-durability", default="volatile",
                    choices=["volatile", "transient_local"])
    ap.add_argument("--count", type=int, default=500,
                    help="number of samples to collect (after warmup)")
    ap.add_argument("--warmup", type=int, default=50,
                    help="messages to discard before recording")
    ap.add_argument("--rate-hz", type=float, default=100.0,
                    help="publish rate in Hz")
    args = ap.parse_args()

    rclpy.init()

    qos = _make_qos(args.qos_reliability, args.qos_durability)
    ponger = Ponger(qos)
    pinger = Pinger(qos, args.payload_bytes)

    executor = MultiThreadedExecutor(num_threads=4)
    executor.add_node(ponger)
    executor.add_node(pinger)

    spin_thread = threading.Thread(target=executor.spin, daemon=True)
    spin_thread.start()

    # Allow DDS discovery to complete before sending the first ping.
    time.sleep(1.0)

    period = 1.0 / args.rate_hz
    total = args.warmup + args.count

    for i in range(total):
        lat = pinger.send_ping()
        if i >= args.warmup:
            if lat is not None:
                print(f"{lat:.3f}", flush=True)
            else:
                print(f"WARN: ping {i} timed out", file=sys.stderr)
        time.sleep(period)

    executor.shutdown()
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
