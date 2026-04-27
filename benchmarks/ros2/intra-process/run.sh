#!/usr/bin/env bash
# benchmarks/ros2/intra-process/run.sh — intra-process vs inter-process latency.
#
# Compares ROS 2 intra-process communication latency against the regular
# (inter-process) pub/sub latency for the same node.
#
# Methodology:
#   1. Run latency_probe.py with intra-process enabled (--intra-process).
#   2. Run latency_probe.py with intra-process disabled (default).
#   3. Emit a single JSON with metrics for both cases so compare.py can diff them.
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--count=500] [--warmup=50] [--rate-hz=100]
#            [--payloads=1024,65536]
#
# Requires: ROS 2 (Humble+), rclpy, std_msgs.
#
# Writes: <run-dir>/ros2.intra_process.json   (schema: docs/result-schema.md)
#         <run-dir>/ros2.intra_process.raw.txt
set -euo pipefail

BENCH_ID="ros2.intra_process"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROBE="${ROOT}/benchmarks/ros2/pubsub-latency/latency_probe.py"

PLATFORM=""
RUN_DIR=""
COUNT="500"
WARMUP="50"
RATE_HZ="100"
PAYLOADS="1024,65536"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --count=*)      COUNT="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
    --rate-hz=*)    RATE_HZ="${arg#*=}" ;;
    --payloads=*)   PAYLOADS="${arg#*=}" ;;
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

if [[ ! -f "${PROBE}" ]]; then
  echo "ERROR: latency_probe.py not found at ${PROBE}" >&2
  exit 1
fi

IFS=',' read -ra PAYLOAD_LIST <<< "${PAYLOADS}"

# ─── helper: run one probe case ───────────────────────────────────────────────
run_case() {
  local label="$1"       # e.g. "intra_1024" or "inter_1024"
  local payload_bytes="$2"
  local extra_args="${3:-}"   # e.g. "--intra-process"
  local samples_file="${SAMPLES_DIR}/${label}.samples"

  echo "[${BENCH_ID}] >>> ${label} (payload=${payload_bytes}B ${extra_args})" | tee -a "${RAW}"

  python3 "${PROBE}" \
    --payload-bytes "${payload_bytes}" \
    --count "${COUNT}" \
    --warmup "${WARMUP}" \
    --rate-hz "${RATE_HZ}" \
    ${extra_args} \
    2>>"${RAW}" > "${samples_file}" || {
      echo "[${BENCH_ID}] WARN: ${label} failed or produced no samples" | tee -a "${RAW}"
      return 0
  }
  echo "[${BENCH_ID}] ${label}: $(wc -l < "${samples_file}") samples" | tee -a "${RAW}"
}

# ─── run all cases ────────────────────────────────────────────────────────────
for payload in "${PAYLOAD_LIST[@]}"; do
  run_case "inter_${payload}" "${payload}" ""
  run_case "intra_${payload}" "${payload}" "--intra-process"
done

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_COUNT="${COUNT}" \
PT_WARMUP="${WARMUP}" \
PT_RATE_HZ="${RATE_HZ}" \
PT_PAYLOADS="${PAYLOADS}" \
PT_SAMPLES_DIR="${SAMPLES_DIR}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket, glob as _glob

def env(k, cast=str):
    return cast(os.environ[k])

def load_samples(path):
    samples = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    samples.append(float(line))
                except ValueError:
                    pass
    except FileNotFoundError:
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

samples_dir = env("PT_SAMPLES_DIR")
payloads = env("PT_PAYLOADS").split(",")

metrics = {}
raw_samples = {}

for payload in payloads:
    for mode in ("inter", "intra"):
        label = f"{mode}_{payload}"
        path = os.path.join(samples_dir, f"{label}.samples")
        s = load_samples(path)
        if s:
            key = f"latency_{mode}_{payload}b"
            metrics[key] = stats(s, "us")
            raw_samples[key] = s

if not metrics:
    raise SystemExit("no samples collected")

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "count":     int(env("PT_COUNT")),
        "warmup":    int(env("PT_WARMUP")),
        "rate_hz":   float(env("PT_RATE_HZ")),
        "payloads":  env("PT_PAYLOADS"),
    },
    "metrics": metrics,
    "raw_samples": raw_samples,
    "iterations": int(env("PT_COUNT")),
    "warmup_s":   0,
    "notes": (
        "intra_*: ROS 2 intra-process communication (zero-copy within process). "
        "inter_*: standard pub/sub (DDS transport, even within same host). "
        "Latency is RTT/2 (one-way estimate via ping-pong). "
        "Lower is better."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
