#!/usr/bin/env bash
# benchmarks/system/cpu/sysbench/run.sh — minimal end-to-end CPU benchmark.
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>] [--threads=N] [--duration=S] [--iterations=N] [--prime=N]
#
# - If --run-dir is omitted, calls scripts/env-snapshot.sh to create one.
# - Writes <run-dir>/system.cpu.sysbench.json (schema: docs/result-schema.md).
# - Also keeps the raw sysbench output as <run-dir>/system.cpu.sysbench.raw.txt.
#
# Requires: sysbench (apt: `sudo apt-get install -y sysbench`), python3.
set -euo pipefail

BENCH_ID="system.cpu.sysbench"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
THREADS="$(nproc 2>/dev/null || echo 4)"
DURATION_S="10"
ITERATIONS="5"
WARMUP_S="3"
PRIME="20000"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --threads=*)    THREADS="${arg#*=}" ;;
    --duration=*)   DURATION_S="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP_S="${arg#*=}" ;;
    --prime=*)      PRIME="${arg#*=}" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  echo "ERROR: --platform=<id> is required" >&2
  exit 2
fi

if ! command -v sysbench >/dev/null 2>&1; then
  echo "ERROR: 'sysbench' not found. Install with:  sudo apt-get install -y sysbench" >&2
  exit 127
fi

# Create a run dir if the caller didn't pass one.
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}")"
fi
mkdir -p "${RUN_DIR}"

RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
: > "${RAW}"

echo "[${BENCH_ID}] platform=${PLATFORM} threads=${THREADS} duration=${DURATION_S}s iterations=${ITERATIONS}"

# Warm-up (discarded).
if (( WARMUP_S > 0 )); then
  echo "[${BENCH_ID}] warmup ${WARMUP_S}s..."
  sysbench cpu --threads="${THREADS}" --time="${WARMUP_S}" --cpu-max-prime="${PRIME}" run >/dev/null 2>&1 || true
fi

# Iterations.
SAMPLES_FILE="$(mktemp)"
trap 'rm -f "${SAMPLES_FILE}"' EXIT

for ((i = 1; i <= ITERATIONS; i++)); do
  echo "[${BENCH_ID}] iter ${i}/${ITERATIONS}..."
  {
    echo "===== iter ${i} ====="
    sysbench cpu --threads="${THREADS}" --time="${DURATION_S}" --cpu-max-prime="${PRIME}" run
  } | tee -a "${RAW}" \
    | awk -v out="${SAMPLES_FILE}" '
        /events per second:/ {
          # line looks like "    events per second:   1234.56"
          val = $NF
          print val >> out
        }
      '
done

if [[ ! -s "${SAMPLES_FILE}" ]]; then
  echo "ERROR: no samples parsed from sysbench output. See ${RAW}" >&2
  exit 1
fi

# Aggregate + write JSON via Python (statistics stdlib).
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_THREADS="${THREADS}" \
PT_DURATION_S="${DURATION_S}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP_S="${WARMUP_S}" \
PT_PRIME="${PRIME}" \
PT_SAMPLES_FILE="${SAMPLES_FILE}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket

def env(k, cast=str):
    return cast(os.environ[k])

samples = []
with open(env("PT_SAMPLES_FILE")) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            samples.append(float(line))
        except ValueError:
            pass

if not samples:
    raise SystemExit("no samples after parse")

samples_sorted = sorted(samples)
def pct(p):
    if len(samples_sorted) == 1:
        return samples_sorted[0]
    k = (len(samples_sorted) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(samples_sorted) - 1)
    if f == c:
        return samples_sorted[f]
    return samples_sorted[f] + (samples_sorted[c] - samples_sorted[f]) * (k - f)

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform": env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname(),
    "env_ref": "env.json",
    "params": {
        "threads": int(env("PT_THREADS")),
        "duration_s": int(env("PT_DURATION_S")),
        "cpu_max_prime": int(env("PT_PRIME")),
    },
    "metrics": {
        "events_per_sec": {
            "p50": pct(50),
            "p95": pct(95),
            "min": min(samples),
            "max": max(samples),
            "avg": statistics.fmean(samples),
            "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
            "unit": "1/s",
        }
    },
    "raw_samples": samples,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s": int(env("PT_WARMUP_S")),
    "notes": "sysbench cpu, single-process. Numbers are events/s reported per iteration.",
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
