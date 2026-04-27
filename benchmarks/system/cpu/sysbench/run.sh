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
TOOL_USED="sysbench"

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
  echo "WARN: 'sysbench' not found; using python3 CPU fallback (prime sieve)." >&2
  echo "      Install with:  sudo apt-get install -y sysbench" >&2
  TOOL_USED="python3"
fi

# Create a run dir if the caller didn't pass one.
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}")"
fi
mkdir -p "${RUN_DIR}"

RAW="${RUN_DIR}/${BENCH_ID}.raw.txt"
JSON_OUT="${RUN_DIR}/${BENCH_ID}.json"
: > "${RAW}"

echo "[${BENCH_ID}] platform=${PLATFORM} tool=${TOOL_USED} threads=${THREADS} duration=${DURATION_S}s iterations=${ITERATIONS}"

SAMPLES_FILE="$(mktemp)"
trap 'rm -f "${SAMPLES_FILE}"' EXIT

if [[ "${TOOL_USED}" == "sysbench" ]]; then
  # ── sysbench path ──────────────────────────────────────────────────────────
  # Warm-up (discarded).
  if (( WARMUP_S > 0 )); then
    echo "[${BENCH_ID}] warmup ${WARMUP_S}s..."
    sysbench cpu --threads="${THREADS}" --time="${WARMUP_S}" --cpu-max-prime="${PRIME}" run >/dev/null 2>&1 || true
  fi

  for ((i = 1; i <= ITERATIONS; i++)); do
    echo "[${BENCH_ID}] iter ${i}/${ITERATIONS}..."
    {
      echo "===== iter ${i} ====="
      sysbench cpu --threads="${THREADS}" --time="${DURATION_S}" --cpu-max-prime="${PRIME}" run
    } | tee -a "${RAW}" \
      | awk -v out="${SAMPLES_FILE}" '
          /events per second:/ {
            val = $NF
            print val >> out
          }
        '
  done

else
  # ── Python3 fallback: multi-threaded prime sieve ───────────────────────────
  echo "[${BENCH_ID}] tool: python3 CPU fallback (prime sieve, ${THREADS} threads)" | tee -a "${RAW}"

  # Warm-up
  if (( WARMUP_S > 0 )); then
    echo "[${BENCH_ID}] warmup ${WARMUP_S}s..."
    python3 -c "
import time, math
deadline = time.monotonic() + ${WARMUP_S}
n = 0
while time.monotonic() < deadline:
    for x in range(2, int(math.sqrt(${PRIME})) + 1):
        pass
    n += 1
" 2>/dev/null || true
  fi

  PT_THREADS="${THREADS}" \
  PT_DURATION_S="${DURATION_S}" \
  PT_ITERATIONS="${ITERATIONS}" \
  PT_PRIME="${PRIME}" \
  PT_SAMPLES_FILE="${SAMPLES_FILE}" \
  PT_RAW="${RAW}" \
  python3 - <<'PYCPU'
import os, time, math
from concurrent.futures import ThreadPoolExecutor

threads    = int(os.environ["PT_THREADS"])
duration_s = int(os.environ["PT_DURATION_S"])
iterations = int(os.environ["PT_ITERATIONS"])
prime_max  = int(os.environ["PT_PRIME"])
out_path   = os.environ["PT_SAMPLES_FILE"]
raw_path   = os.environ["PT_RAW"]

def _count_primes(limit: int) -> int:
    """Return number of primes up to limit using trial-division.
    Intentionally conservative (O(n·√n)) to serve as a CPU stress load.
    Results will be lower than sysbench's optimised implementation — this
    is a conservative lower bound, not a competitive benchmark.
    """
    count = 0
    for n in range(2, limit + 1):
        if all(n % d != 0 for d in range(2, int(math.sqrt(n)) + 1)):
            count += 1
    return count

def worker(stop_at: float):
    events = 0
    while time.monotonic() < stop_at:
        _count_primes(prime_max)
        events += 1
    return events

for i in range(iterations):
    t0 = time.monotonic()
    stop_at = t0 + duration_s
    futures = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        for _ in range(threads):
            futures.append(ex.submit(worker, stop_at))
        results = [f.result() for f in futures]
    elapsed = time.monotonic() - t0
    total_events = sum(results)
    eps = total_events / elapsed
    msg = f"iter={i+1} events={total_events} elapsed={elapsed:.2f}s eps={eps:.2f}"
    print(msg)
    with open(raw_path, 'a') as rf:
        rf.write(msg + "\n")
    with open(out_path, 'a') as sf:
        sf.write(f"{eps:.4f}\n")
PYCPU
fi

if [[ ! -s "${SAMPLES_FILE}" ]]; then
  echo "ERROR: no samples collected. See ${RAW}" >&2
  exit 1
fi

# Aggregate + write JSON via Python (statistics stdlib).
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_TOOL="${TOOL_USED}" \
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

tool = env("PT_TOOL")
doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform": env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname(),
    "env_ref": "env.json",
    "params": {
        "tool": tool,
        "threads": int(env("PT_THREADS")),
        "duration_s": int(env("PT_DURATION_S")),
        "cpu_max_prime": int(env("PT_PRIME")),
    },
    "metrics": {
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
    "notes": (
        "sysbench cpu: prime sieve, single-process, events/s per iteration. "
        "python3 fallback: multi-threaded trial-division prime sieve (O(n*sqrt(n))). "
        "Fallback values are a CONSERVATIVE LOWER BOUND — expect 10-100x fewer events/s "
        "than sysbench due to Python overhead and unoptimised algorithm."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
