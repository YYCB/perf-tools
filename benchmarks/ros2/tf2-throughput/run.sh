#!/usr/bin/env bash
# benchmarks/ros2/tf2-throughput/run.sh — TF2 transform lookup throughput.
#
# Measures how many tf2 lookups/second the tf2 buffer can sustain under load,
# and the latency (µs) of a single lookup.
#
# Two modes:
#   buffer     — pure in-process tf2 buffer (no DDS overhead); measures raw
#                BufferCore lookup throughput.
#   listener   — tf2_ros.Buffer backed by a ROS 2 subscriber; realistic
#                end-to-end including DDS roundtrip.
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--duration=30] [--depth=100] [--iterations=5]
#            [--modes=buffer,listener]
#
# Requires: ROS 2 (Humble+), rclpy, tf2_ros, geometry_msgs.
#
# Writes: <run-dir>/ros2.tf2_throughput.json   (schema: docs/result-schema.md)
#         <run-dir>/ros2.tf2_throughput.raw.txt
set -euo pipefail

BENCH_ID="ros2.tf2_throughput"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
DURATION="30"
DEPTH="100"
ITERATIONS="5"
MODES="buffer,listener"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --duration=*)   DURATION="${arg#*=}" ;;
    --depth=*)      DEPTH="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --modes=*)      MODES="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  echo "ERROR: --platform=<id> is required" >&2
  exit 2
fi

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}")"
fi

mkdir -p "${RUN_DIR}"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
SAMPLES_DIR="${RUN_DIR}/${BENCH_ID}.samples"
mkdir -p "${SAMPLES_DIR}"

: > "${RAW}"

if ! command -v ros2 &>/dev/null; then
  echo "ERROR: ros2 not found. Source ROS 2 first: source /opt/ros/humble/setup.bash" >&2
  exit 1
fi

echo "[${BENCH_ID}] duration=${DURATION}s depth=${DEPTH} iterations=${ITERATIONS} modes=${MODES}" | tee -a "${RAW}"

# ─── TF2 benchmark Python script ─────────────────────────────────────────────
TF2_SCRIPT="/tmp/perf_tf2_bench_$$.py"
cat > "${TF2_SCRIPT}" <<'TF2PY'
#!/usr/bin/env python3
"""TF2 throughput and latency benchmark.

Modes:
  buffer   — pure BufferCore, no ROS 2 involved
  listener — tf2_ros.Buffer (requires ROS 2 / rclpy)

Outputs one line per measurement: <mode> <lookups_per_sec> <avg_latency_us>
"""
from __future__ import annotations
import argparse, sys, time

def bench_buffer_core(duration_s: float, depth: int) -> tuple[float, float]:
    """Pure BufferCore (no DDS). Uses geometry_msgs transforms."""
    try:
        import tf2_ros
        from geometry_msgs.msg import TransformStamped
        import builtin_interfaces.msg as bim
    except ImportError as e:
        print(f"WARN: tf2_ros not available: {e}", file=sys.stderr)
        return 0.0, 0.0

    buf = tf2_ros.BufferCore(rclpy.duration.Duration(seconds=60))  # type: ignore

    # Populate buffer with a chain: world -> base -> sensor (100 transforms)
    import rclpy.time
    for i in range(depth):
        t = TransformStamped()
        t.header.stamp = bim.Time(sec=i, nanosec=0)
        t.header.frame_id = "world"
        t.child_frame_id  = f"link_{i}"
        t.transform.rotation.w = 1.0
        buf.set_transform(t, "authority")

    deadline = time.monotonic() + duration_s
    count = 0
    latencies: list[float] = []
    src = "world"
    dst = f"link_{depth // 2}"
    t_lookup = bim.Time(sec=depth - 1, nanosec=0)

    while time.monotonic() < deadline:
        t0 = time.monotonic_ns()
        try:
            buf.lookup_transform_core(src, dst, t_lookup)
        except Exception:
            break
        latencies.append((time.monotonic_ns() - t0) / 1_000.0)
        count += 1

    if not latencies:
        return 0.0, 0.0
    return count / duration_s, sum(latencies) / len(latencies)


def bench_listener(duration_s: float, depth: int) -> tuple[float, float]:
    """tf2_ros.Buffer backed by rclpy node + subscriber."""
    try:
        import rclpy
        import tf2_ros
        from geometry_msgs.msg import TransformStamped
        import builtin_interfaces.msg as bim
        import threading
    except ImportError as e:
        print(f"WARN: rclpy / tf2_ros not available: {e}", file=sys.stderr)
        return 0.0, 0.0

    rclpy.init()
    node = rclpy.create_node("perf_tf2_bench")
    buf  = tf2_ros.Buffer()
    listener = tf2_ros.TransformListener(buf, node)  # noqa
    broadcaster = tf2_ros.TransformBroadcaster(node)

    spin_thread = threading.Thread(target=rclpy.spin, args=(node,), daemon=True)
    spin_thread.start()

    # Publish transforms
    now = node.get_clock().now()
    for i in range(depth):
        t = TransformStamped()
        t.header.stamp = now.to_msg()
        t.header.frame_id = "world"
        t.child_frame_id  = f"link_{i}"
        t.transform.rotation.w = 1.0
        broadcaster.sendTransform(t)

    time.sleep(0.5)  # let transforms arrive

    deadline = time.monotonic() + duration_s
    count = 0
    latencies: list[float] = []
    dst = f"link_{depth // 2}"
    ts  = rclpy.time.Time(seconds=0, nanoseconds=0)

    while time.monotonic() < deadline:
        t0 = time.monotonic_ns()
        try:
            buf.lookup_transform("world", dst, ts)
        except Exception:
            time.sleep(0.001)
            continue
        latencies.append((time.monotonic_ns() - t0) / 1_000.0)
        count += 1

    rclpy.shutdown()
    if not latencies:
        return 0.0, 0.0
    return count / duration_s, sum(latencies) / len(latencies)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True, choices=["buffer", "listener"])
    ap.add_argument("--duration", type=float, default=30.0)
    ap.add_argument("--depth", type=int, default=100)
    args = ap.parse_args()

    if args.mode == "buffer":
        # buffer mode works without rclpy DDS
        try:
            import rclpy
            import rclpy.duration
        except ImportError as e:
            print(f"WARN: rclpy not available: {e}", file=sys.stderr)
            print(f"0.0 0.0"); return
        rclpy.init()
        fps, lat_us = bench_buffer_core(args.duration, args.depth)
        rclpy.shutdown()
    else:
        fps, lat_us = bench_listener(args.duration, args.depth)

    print(f"{fps:.2f} {lat_us:.3f}")


if __name__ == "__main__":
    main()
TF2PY
chmod +x "${TF2_SCRIPT}"
trap 'rm -f "${TF2_SCRIPT}"' EXIT

IFS=',' read -ra MODE_LIST <<< "${MODES}"

for mode in "${MODE_LIST[@]}"; do
  SAMPLES_FILE="${SAMPLES_DIR}/${mode}.samples"
  : > "${SAMPLES_FILE}"
  echo "[${BENCH_ID}] mode=${mode}" | tee -a "${RAW}"

  for (( iter=0; iter<ITERATIONS; iter++ )); do
    RESULT="$(python3 "${TF2_SCRIPT}" \
      --mode "${mode}" \
      --duration "${DURATION}" \
      --depth "${DEPTH}" \
      2>>"${RAW}" || echo "")"
    if [[ -n "${RESULT}" ]]; then
      echo "${RESULT}" >> "${SAMPLES_FILE}"
      echo "[${BENCH_ID}] ${mode} iter=${iter}: ${RESULT}" | tee -a "${RAW}"
    fi
  done
done

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_DURATION="${DURATION}" \
PT_DEPTH="${DEPTH}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_MODES="${MODES}" \
PT_SAMPLES_DIR="${SAMPLES_DIR}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket

def env(k, cast=str):
    return cast(os.environ[k])

def load_samples(path):
    fps_list, lat_list = [], []
    try:
        with open(path) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    try:
                        fps_list.append(float(parts[0]))
                        lat_list.append(float(parts[1]))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return fps_list, lat_list

def stats(samples, unit):
    if not samples:
        return None
    ss = sorted(samples)
    def pct(p):
        if len(ss) == 1: return ss[0]
        k = (len(ss) - 1) * (p / 100.0)
        f = int(k); c = min(f + 1, len(ss) - 1)
        if f == c: return ss[f]
        return ss[f] + (ss[c] - ss[f]) * (k - f)
    return {
        "p50": pct(50), "p95": pct(95), "p99": pct(99),
        "min": min(samples), "max": max(samples),
        "avg": statistics.fmean(samples),
        "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "unit": unit,
    }

metrics = {}
raw_all = {}

for mode in env("PT_MODES").split(","):
    path = os.path.join(env("PT_SAMPLES_DIR"), f"{mode}.samples")
    fps_list, lat_list = load_samples(path)
    if fps_list:
        metrics[f"{mode}_throughput_lookup_s"] = stats(fps_list, "lookups/s")
        raw_all[f"{mode}_fps"] = fps_list
    if lat_list:
        metrics[f"{mode}_latency_us"] = stats(lat_list, "us")
        raw_all[f"{mode}_lat_us"] = lat_list

if not metrics:
    raise SystemExit("no tf2 throughput samples collected")

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "duration_s": int(env("PT_DURATION")),
        "depth":      int(env("PT_DEPTH")),
        "iterations": int(env("PT_ITERATIONS")),
        "modes":      env("PT_MODES"),
    },
    "metrics": metrics,
    "raw_samples": raw_all,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   0,
    "notes": (
        "buffer: pure in-process tf2 BufferCore lookup (no DDS). "
        "listener: tf2_ros.Buffer via rclpy node + TF broadcaster (includes DDS). "
        "throughput = lookups/s sustained over --duration; latency = µs/lookup. "
        "Higher throughput is better; lower latency is better."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
