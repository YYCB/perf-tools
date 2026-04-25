#!/usr/bin/env bash
# benchmarks/<layer>/<topic>/<name>/run.sh — TEMPLATE
#
# Replace placeholders marked with TODO. Keep the I/O contract:
#   --platform=<id>                 (required)
#   --run-dir=<dir>                 (optional; auto-snapshot if missing)
#   writes <run-dir>/<BENCH_ID>.json (schema: docs/result-schema.md)
#   keeps <run-dir>/<BENCH_ID>.raw.txt
set -euo pipefail

# TODO: change BENCH_ID to match the directory path (dotted).
BENCH_ID="layer.topic.name"

# Resolve repo root from this file's location. Adjust the number of `..`
# if you nest the directory more or less deeply.
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
THREADS="$(nproc 2>/dev/null || echo 4)"
DURATION_S="10"
ITERATIONS="5"
WARMUP_S="3"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --threads=*)    THREADS="${arg#*=}" ;;
    --duration=*)   DURATION_S="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP_S="${arg#*=}" ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
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

RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
: > "${RAW}"

SAMPLES_FILE="$(mktemp)"
trap 'rm -f "${SAMPLES_FILE}"' EXIT

echo "[${BENCH_ID}] warmup ${WARMUP_S}s..."
sleep "${WARMUP_S}"   # TODO: replace with a warm-up invocation of your tool

for ((i = 1; i <= ITERATIONS; i++)); do
  echo "[${BENCH_ID}] iter ${i}/${ITERATIONS}..."
  # TODO: replace this block with your benchmark command. It must:
  #   - run for ~${DURATION_S} seconds
  #   - print one numeric sample to stdout (or be parsed from stderr/log)
  #   - append the sample(s) to ${SAMPLES_FILE}
  {
    echo "===== iter ${i} ====="
    sample="$(awk -v s="${i}" 'BEGIN{srand(s); print 100 + rand()*5}')"
    echo "events: ${sample}"
    echo "${sample}" >> "${SAMPLES_FILE}"
  } | tee -a "${RAW}" >/dev/null
done

if [[ ! -s "${SAMPLES_FILE}" ]]; then
  echo "ERROR: no samples collected. See ${RAW}" >&2
  exit 1
fi

PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_THREADS="${THREADS}" \
PT_DURATION_S="${DURATION_S}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP_S="${WARMUP_S}" \
PT_SAMPLES_FILE="${SAMPLES_FILE}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket

def env(k):
    return os.environ[k]

samples = []
with open(env("PT_SAMPLES_FILE")) as f:
    for line in f:
        line = line.strip()
        if line:
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
    f = int(k); c = min(f + 1, len(samples_sorted) - 1)
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
    },
    "metrics": {
        # TODO: rename / adjust to your real metric.
        "events_per_sec": {
            "p50": pct(50),
            "p95": pct(95),
            "p99": pct(99),
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
    "notes": "TODO: describe power mode, fan, SDK version, anything that affects comparability",
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
