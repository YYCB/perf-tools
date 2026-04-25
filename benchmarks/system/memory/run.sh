#!/usr/bin/env bash
# benchmarks/system/memory/run.sh — memory bandwidth benchmark.
#
# Tool priority (first found wins):
#   stream / stream_c  — industry-standard DRAM bandwidth; Triad operation.
#   mbw                — memory bandwidth tester; MEMCPY method.
#   python3            — pure-Python memoryview copy (lower bound; no deps).
#
# Install hints:
#   apt-get install -y stream          (or compile from cs.virginia.edu/stream)
#   apt-get install -y mbw
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--iterations=5] [--warmup=3] [--array-mb=512]
#
# Writes: <run-dir>/system.memory.json  (schema: docs/result-schema.md)
#         <run-dir>/system.memory.raw.txt
set -euo pipefail

BENCH_ID="system.memory"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
ITERATIONS="5"
WARMUP_S="3"
ARRAY_MB="512"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP_S="${arg#*=}" ;;
    --array-mb=*)   ARRAY_MB="${arg#*=}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

[[ -z "${PLATFORM}" ]] && { echo "ERROR: --platform=<id> is required" >&2; exit 2; }

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}")"
fi
mkdir -p "${RUN_DIR}"

RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
: > "${RAW}"

SAMPLES_FILE="$(mktemp)"
TOOL_USED=""
trap 'rm -f "${SAMPLES_FILE}"' EXIT

echo "[${BENCH_ID}] platform=${PLATFORM} array_mb=${ARRAY_MB} iterations=${ITERATIONS}"

# ─── warm-up ──────────────────────────────────────────────────────────────────
if (( WARMUP_S > 0 )); then
  echo "[${BENCH_ID}] warmup ${WARMUP_S}s..."
  sleep "${WARMUP_S}"
fi

# ─── tool dispatch ────────────────────────────────────────────────────────────
STREAM_CMD="$(command -v stream 2>/dev/null || command -v stream_c 2>/dev/null || true)"

if [[ -n "${STREAM_CMD}" ]]; then
  TOOL_USED="stream"
  for ((i = 1; i <= ITERATIONS; i++)); do
    echo "[${BENCH_ID}] stream iter ${i}/${ITERATIONS}..."
    {
      echo "===== iter ${i} ====="
      "${STREAM_CMD}" 2>&1
    } | tee -a "${RAW}" | \
      awk '/Triad:/ { print $2 }' >> "${SAMPLES_FILE}" || true
  done

elif command -v mbw >/dev/null 2>&1; then
  TOOL_USED="mbw"
  for ((i = 1; i <= ITERATIONS; i++)); do
    echo "[${BENCH_ID}] mbw iter ${i}/${ITERATIONS}..."
    {
      echo "===== iter ${i} ====="
      mbw -t 0 "${ARRAY_MB}" 2>&1
    } | tee -a "${RAW}" | \
      awk '/MEMCPY/ { print $5 }' >> "${SAMPLES_FILE}" || true
  done

else
  TOOL_USED="python3-memcpy"
  echo "WARN: neither stream nor mbw found; using Python memoryview fallback." >&2
  {
    echo "===== python3 memcpy fallback ====="
    PT_ARRAY_MB="${ARRAY_MB}" \
    PT_ITERS="${ITERATIONS}" \
    PT_SF="${SAMPLES_FILE}" \
    python3 - <<'PYMEM'
import os, time

array_bytes = int(os.environ["PT_ARRAY_MB"]) * 1024 * 1024
iters = int(os.environ["PT_ITERS"])
src = bytearray(array_bytes)
dst = bytearray(array_bytes)
memoryview(src)[:] = bytes(array_bytes)

with open(os.environ["PT_SF"], "w") as sf:
    for _ in range(iters):
        t0 = time.perf_counter()
        memoryview(dst)[:] = memoryview(src)
        elapsed = time.perf_counter() - t0
        bw_mbs = (array_bytes / elapsed) / (1024.0 * 1024.0)
        sf.write(f"{bw_mbs:.2f}\n")
PYMEM
  } | tee -a "${RAW}" > /dev/null
fi

if [[ ! -s "${SAMPLES_FILE}" ]]; then
  echo "ERROR: no bandwidth samples collected. See ${RAW}" >&2
  exit 1
fi

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_TOOL="${TOOL_USED}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP_S="${WARMUP_S}" \
PT_ARRAY_MB="${ARRAY_MB}" \
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

ss = sorted(samples)


def pct(p):
    if len(ss) == 1:
        return ss[0]
    k = (len(ss) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(ss) - 1)
    if f == c:
        return ss[f]
    return ss[f] + (ss[c] - ss[f]) * (k - f)


doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "tool":       env("PT_TOOL"),
        "iterations": int(env("PT_ITERATIONS")),
        "array_mb":   int(env("PT_ARRAY_MB")),
    },
    "metrics": {
        "bandwidth": {
            "p50":   pct(50),
            "p95":   pct(95),
            "p99":   pct(99),
            "min":   min(samples),
            "max":   max(samples),
            "avg":   statistics.fmean(samples),
            "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
            "unit":  "MB/s",
        }
    },
    "raw_samples": samples,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   int(env("PT_WARMUP_S")),
    "notes": (
        f"tool={env('PT_TOOL')}. "
        "stream: Triad operation (peak DRAM bandwidth). "
        "mbw: MEMCPY method. "
        "python3: pure-Python memoryview copy (conservative lower bound)."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
