#!/usr/bin/env bash
# benchmarks/ros2/dds-vendors/run.sh — compare ROS 2 middleware latency across DDS vendors.
#
# Runs ros2/pubsub-latency for each RMW in --rmw-list, then merges results into
# a single JSON whose metric keys are prefixed with the RMW name.
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--rmw-list=rmw_cyclonedds_cpp,rmw_fastrtps_cpp]
#            [--count=500] [--warmup=50] [--rate-hz=100]
#            [--payloads=1024,65536,1048576]
#            [--qos-pairs=reliable+volatile,best_effort+volatile]
#
# Requires: ROS 2 (Humble+), rclpy, std_msgs; one or more RMW packages installed.
#
# Writes: <run-dir>/ros2.dds_vendors.json  (schema: docs/result-schema.md)
#         <run-dir>/ros2.dds_vendors.raw.txt
set -euo pipefail

BENCH_ID="ros2.dds_vendors"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
RMW_LIST="rmw_cyclonedds_cpp,rmw_fastrtps_cpp"
COUNT="500"
WARMUP="50"
RATE_HZ="100"
PAYLOADS="1024,65536,1048576"
QOS_PAIRS="reliable+volatile,best_effort+volatile"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --rmw-list=*)   RMW_LIST="${arg#*=}" ;;
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

PUBSUB_RUN="${ROOT}/benchmarks/ros2/pubsub-latency/run.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

IFS=',' read -ra RMW_ARRAY <<< "${RMW_LIST}"

for rmw in "${RMW_ARRAY[@]}"; do
  echo "[${BENCH_ID}] ---- testing rmw=${rmw} ----"
  rmw_dir="${SCRATCH}/${rmw}"
  mkdir -p "${rmw_dir}"
  # Provide a minimal env.json so the sub-benchmark skips env-snapshot.
  echo '{"schema_version":"1","kind":"env-snapshot","platform":"'${PLATFORM}'"}' \
    > "${rmw_dir}/env.json"
  {
    echo "===== rmw=${rmw} ====="
    RMW_IMPLEMENTATION="${rmw}" \
      bash "${PUBSUB_RUN}" \
        --platform="${PLATFORM}" \
        --run-dir="${rmw_dir}" \
        --count="${COUNT}" \
        --warmup="${WARMUP}" \
        --rate-hz="${RATE_HZ}" \
        --payloads="${PAYLOADS}" \
        --qos-pairs="${QOS_PAIRS}"
  } 2>&1 | tee -a "${RAW}"
done

# Merge all per-RMW JSONs into one combined document.
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_RMW_LIST="${RMW_LIST}" \
PT_PAYLOADS="${PAYLOADS}" \
PT_QOS_PAIRS="${QOS_PAIRS}" \
PT_COUNT="${COUNT}" \
PT_WARMUP="${WARMUP}" \
PT_RATE_HZ="${RATE_HZ}" \
PT_SCRATCH="${SCRATCH}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, datetime, socket
from pathlib import Path


def env(k):
    return os.environ[k]


scratch = Path(env("PT_SCRATCH"))
rmw_list = env("PT_RMW_LIST").split(",")

metrics: dict = {}
for rmw in rmw_list:
    bench_json = scratch / rmw / "ros2.pubsub_latency.json"
    if not bench_json.exists():
        print(f"WARN: missing results for rmw={rmw} ({bench_json})", flush=True)
        continue
    sub = json.loads(bench_json.read_text())
    for k, v in sub.get("metrics", {}).items():
        metrics[f"{rmw}.{k}"] = v

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
        "rmw_list":       rmw_list,
        "payloads_bytes": [int(x) for x in env("PT_PAYLOADS").split(",")],
        "qos_pairs":      env("PT_QOS_PAIRS").split(","),
        "count_per_case": int(env("PT_COUNT")),
        "warmup_msgs":    int(env("PT_WARMUP")),
        "rate_hz":        float(env("PT_RATE_HZ")),
    },
    "metrics": metrics,
    "notes": (
        "Metric keys: <rmw>.<payload_case>.latency_us. "
        "one-way latency = RTT/2. Compare same payload/QoS rows across RMW prefixes."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
