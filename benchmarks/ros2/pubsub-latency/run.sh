#!/usr/bin/env bash
# benchmarks/ros2/pubsub-latency/run.sh — ROS 2 pub/sub one-way latency benchmark.
#
# Sweeps three payload sizes and two QoS combinations, collecting N latency
# samples per case via latency_probe.py (ping-pong RTT/2).
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--count=500] [--warmup=50] [--rate-hz=100]
#            [--payloads=1024,65536,1048576]
#            [--qos-pairs=reliable+volatile,best_effort+volatile]
#
# Set RMW_IMPLEMENTATION before calling to select middleware.
# Requires: ROS 2 (Humble+), rclpy, std_msgs.
#
# Writes: <run-dir>/ros2.pubsub_latency.json  (schema: docs/result-schema.md)
#         <run-dir>/ros2.pubsub_latency.raw.txt
set -euo pipefail

BENCH_ID="ros2.pubsub_latency"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
COUNT="500"
WARMUP="50"
RATE_HZ="100"
PAYLOADS="1024,65536,1048576"
QOS_PAIRS="reliable+volatile,best_effort+volatile"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --count=*)      COUNT="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
    --rate-hz=*)    RATE_HZ="${arg#*=}" ;;
    --payloads=*)   PAYLOADS="${arg#*=}" ;;
    --qos-pairs=*)  QOS_PAIRS="${arg#*=}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

[[ -z "${PLATFORM}" ]] && { echo "ERROR: --platform=<id> is required" >&2; exit 2; }

if ! command -v ros2 >/dev/null 2>&1; then
  echo "ERROR: 'ros2' not found. Source your ROS 2 setup.bash first." >&2
  exit 127
fi

if ! python3 -c "import rclpy" 2>/dev/null; then
  echo "ERROR: rclpy not importable. Source your ROS 2 setup.bash first." >&2
  exit 127
fi

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}")"
fi
mkdir -p "${RUN_DIR}"

RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
: > "${RAW}"

PROBE="${ROOT}/benchmarks/ros2/pubsub-latency/latency_probe.py"
RMW="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

echo "[${BENCH_ID}] platform=${PLATFORM} rmw=${RMW}"
echo "[${BENCH_ID}] payloads=${PAYLOADS} qos=${QOS_PAIRS}"

IFS=',' read -ra PAYLOAD_LIST <<< "${PAYLOADS}"
IFS=',' read -ra QOS_LIST     <<< "${QOS_PAIRS}"

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "${RESULTS_DIR}"' EXIT

for payload in "${PAYLOAD_LIST[@]}"; do
  for qos_pair in "${QOS_LIST[@]}"; do
    rel="${qos_pair%%+*}"
    dur="${qos_pair##*+}"
    label="payload${payload}_${rel}_${dur}"
    out_file="${RESULTS_DIR}/${label}.txt"

    echo "[${BENCH_ID}] payload=${payload}B  qos=${qos_pair}..."
    {
      echo "===== payload=${payload} qos=${qos_pair} ====="
      python3 "${PROBE}" \
        --payload-bytes "${payload}" \
        --qos-reliability "${rel}" \
        --qos-durability  "${dur}" \
        --count           "${COUNT}" \
        --warmup          "${WARMUP}" \
        --rate-hz         "${RATE_HZ}"
    } 2>> "${RAW}" | tee -a "${RAW}" | grep -E '^[0-9]' > "${out_file}" || true

    if [[ ! -s "${out_file}" ]]; then
      echo "WARN: no samples collected for ${label}" >&2
    fi
  done
done

# Aggregate all case sample files into one schema-v1 JSON.
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_RMW="${RMW}" \
PT_PAYLOADS="${PAYLOADS}" \
PT_QOS_PAIRS="${QOS_PAIRS}" \
PT_COUNT="${COUNT}" \
PT_WARMUP="${WARMUP}" \
PT_RATE_HZ="${RATE_HZ}" \
PT_RESULTS_DIR="${RESULTS_DIR}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket
from pathlib import Path


def env(k, cast=str):
    return cast(os.environ[k])


def pct(sorted_s, p):
    if len(sorted_s) == 1:
        return sorted_s[0]
    k = (len(sorted_s) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_s) - 1)
    if f == c:
        return sorted_s[f]
    return sorted_s[f] + (sorted_s[c] - sorted_s[f]) * (k - f)


results_dir = Path(env("PT_RESULTS_DIR"))
metrics: dict = {}

for txt in sorted(results_dir.glob("*.txt")):
    samples = []
    for line in txt.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            samples.append(float(line))
        except ValueError:
            pass
    if not samples:
        continue
    ss = sorted(samples)
    name = txt.stem  # e.g. payload1024_reliable_volatile
    metrics[f"{name}.latency_us"] = {
        "p50":   pct(ss, 50),
        "p95":   pct(ss, 95),
        "p99":   pct(ss, 99),
        "min":   min(samples),
        "max":   max(samples),
        "avg":   statistics.fmean(samples),
        "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "unit":  "us",
        "count": len(samples),
    }

if not metrics:
    raise SystemExit("no metrics collected — check raw output")

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "rmw":             env("PT_RMW"),
        "payloads_bytes":  [int(x) for x in env("PT_PAYLOADS").split(",")],
        "qos_pairs":       env("PT_QOS_PAIRS").split(","),
        "count_per_case":  int(env("PT_COUNT")),
        "warmup_msgs":     int(env("PT_WARMUP")),
        "rate_hz":         float(env("PT_RATE_HZ")),
    },
    "metrics": metrics,
    "notes": (
        f"one-way latency = RTT/2 via loopback ponger; rmw={env('PT_RMW')}. "
        "Metric key pattern: payload<bytes>_<reliability>_<durability>.latency_us"
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
