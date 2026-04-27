#!/usr/bin/env bash
# benchmarks/ros2/lifecycle-startup/run.sh — ROS 2 lifecycle node startup time.
#
# Measures the wall-clock time for a LifecycleNode to advance through each
# transition: configure → activate → deactivate → cleanup → shutdown.
#
# Uses the ROS 2 CLI (`ros2 lifecycle`) to drive state transitions and
# timestamps each one with nanosecond precision.
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--iterations=10] [--warmup=2]
#            [--node=perf_lifecycle_node]
#
# Requires: ROS 2 (Humble+), rclpy, lifecycle_msgs.
#
# Writes: <run-dir>/ros2.lifecycle_startup.json   (schema: docs/result-schema.md)
#         <run-dir>/ros2.lifecycle_startup.raw.txt
set -euo pipefail

BENCH_ID="ros2.lifecycle_startup"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
ITERATIONS="10"
WARMUP="2"
NODE_NAME="perf_lifecycle_node"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
    --node=*)       NODE_NAME="${arg#*=}" ;;
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

# Verify ROS 2 is available
if ! command -v ros2 &>/dev/null; then
  echo "ERROR: ros2 not found. Source ROS 2 first: source /opt/ros/humble/setup.bash" >&2
  exit 1
fi

echo "[${BENCH_ID}] running lifecycle node startup benchmark" | tee -a "${RAW}"
echo "[${BENCH_ID}] node=${NODE_NAME} iterations=${ITERATIONS} warmup=${WARMUP}" | tee -a "${RAW}"

# ─── inline lifecycle node + timing harness ──────────────────────────────────
# We start a minimal LifecycleNode in a background Python process and measure
# transition times by driving it with ros2 lifecycle commands.
NODE_SCRIPT="/tmp/perf_lifecycle_node_$$.py"

cat > "${NODE_SCRIPT}" <<'NODE_PY'
#!/usr/bin/env python3
"""Minimal LifecycleNode for benchmarking state transitions."""
import sys
import rclpy
from rclpy.lifecycle import LifecycleNode, TransitionCallbackReturn


class PerfLifecycleNode(LifecycleNode):
    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.get_logger().info(f"node created: {name}")

    def on_configure(self, state):
        self.get_logger().info("on_configure")
        return TransitionCallbackReturn.SUCCESS

    def on_activate(self, state):
        self.get_logger().info("on_activate")
        return TransitionCallbackReturn.SUCCESS

    def on_deactivate(self, state):
        self.get_logger().info("on_deactivate")
        return TransitionCallbackReturn.SUCCESS

    def on_cleanup(self, state):
        self.get_logger().info("on_cleanup")
        return TransitionCallbackReturn.SUCCESS

    def on_shutdown(self, state):
        self.get_logger().info("on_shutdown")
        return TransitionCallbackReturn.SUCCESS


def main():
    rclpy.init()
    node = PerfLifecycleNode(sys.argv[1] if len(sys.argv) > 1 else "perf_lifecycle_node")
    rclpy.spin(node)
    rclpy.shutdown()


if __name__ == "__main__":
    main()
NODE_PY
chmod +x "${NODE_SCRIPT}"
trap 'rm -f "${NODE_SCRIPT}"' EXIT

TOTAL="$((WARMUP + ITERATIONS))"

for (( iter=0; iter<TOTAL; iter++ )); do
  # Start node in background
  python3 "${NODE_SCRIPT}" "${NODE_NAME}" &>>"${RAW}" &
  NODE_PID=$!
  sleep 1.0  # wait for node to register

  ITER_FILE="${SAMPLES_DIR}/iter_${iter}.txt"
  : > "${ITER_FILE}"

  # Drive transitions and time each one
  for transition in configure activate deactivate cleanup; do
    T0="$(python3 -c 'import time; print(time.monotonic_ns())')"
    ros2 lifecycle set "/${NODE_NAME}" "${transition}" >> "${RAW}" 2>&1 || true
    T1="$(python3 -c 'import time; print(time.monotonic_ns())')"
    ELAPSED_MS="$(python3 -c "print(($T1 - $T0) / 1e6)")"
    echo "${transition} ${ELAPSED_MS}" >> "${ITER_FILE}"
  done

  kill "${NODE_PID}" 2>/dev/null || true
  wait "${NODE_PID}" 2>/dev/null || true
done

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP="${WARMUP}" \
PT_NODE_NAME="${NODE_NAME}" \
PT_SAMPLES_DIR="${SAMPLES_DIR}" \
PT_TOTAL="${TOTAL}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket

def env(k, cast=str):
    return cast(os.environ[k])

def load_samples(samples_dir, transition, warmup, total):
    samples = []
    for i in range(int(warmup), int(total)):
        path = os.path.join(samples_dir, f"iter_{i}.txt")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0] == transition:
                    try:
                        samples.append(float(parts[1]))
                    except ValueError:
                        pass
    return samples

def stats(samples, unit):
    if not samples:
        return None
    ss = sorted(samples)
    def pct(p):
        if len(ss) == 1:
            return ss[0]
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

transitions = ["configure", "activate", "deactivate", "cleanup"]
metrics = {}
raw_all = {}

for t in transitions:
    s = load_samples(env("PT_SAMPLES_DIR"), t, env("PT_WARMUP"), env("PT_TOTAL"))
    if s:
        metrics[f"{t}_ms"] = stats(s, "ms")
        raw_all[f"{t}_ms"] = s

if not metrics:
    raise SystemExit("no lifecycle timing samples collected")

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "node_name":  env("PT_NODE_NAME"),
        "iterations": int(env("PT_ITERATIONS")),
        "warmup":     int(env("PT_WARMUP")),
    },
    "metrics": metrics,
    "raw_samples": raw_all,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   0,
    "notes": (
        "Wall-clock time for each LifecycleNode state transition "
        "(configure / activate / deactivate / cleanup). "
        "Measured from CLI invocation to successful ros2 lifecycle set return. "
        "Lower is better."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
