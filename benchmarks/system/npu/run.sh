#!/usr/bin/env bash
# benchmarks/system/npu/run.sh — NPU inference throughput & latency benchmark.
#
# Platform dispatch:
#   orin   — trtexec (JetPack TensorRT); --model must be an ONNX file.
#   s100   — hb_perf (Horizon HBDK / BPU); --model must be a compiled .bin file.
#   *      — onnxruntime CPU fallback; --model must be an ONNX file.
#
# Produces two metrics per run:
#   inference_latency   p50/p95/p99/min/max/avg/stdev  (us on Orin, ms elsewhere)
#   throughput_fps_derived       avg  (fps)
#
# Usage:
#   ./run.sh --platform=orin  --model=/path/to/model.onnx  [options]
#   ./run.sh --platform=s100  --model=/path/to/model.bin   [options]
#
# Options:
#   --run-dir=<dir>         (auto-created if omitted)
#   --batch=1               batch size passed to the inference tool
#   --iterations=100        number of inference iterations to measure
#   --warmup=20             iterations to discard before recording
#   --precision=fp16        (Orin/trtexec only: fp32|fp16|int8)
#
# Writes: <run-dir>/system.npu.json  (schema: docs/result-schema.md)
#         <run-dir>/system.npu.raw.txt
set -euo pipefail

BENCH_ID="system.npu"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
MODEL=""
BATCH="1"
ITERATIONS="100"
WARMUP="20"
PRECISION="fp16"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --model=*)      MODEL="${arg#*=}" ;;
    --batch=*)      BATCH="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
    --precision=*)  PRECISION="${arg#*=}" ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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
EXTRA_JSON_FILE="$(mktemp)"
echo '{}' > "${EXTRA_JSON_FILE}"
trap 'rm -f "${SAMPLES_FILE}" "${EXTRA_JSON_FILE}"' EXIT

echo "[${BENCH_ID}] platform=${PLATFORM} batch=${BATCH} precision=${PRECISION} iterations=${ITERATIONS}"

# ─── platform dispatch ────────────────────────────────────────────────────────
case "${PLATFORM}" in

  orin)
    if ! command -v trtexec >/dev/null 2>&1; then
      echo "ERROR: 'trtexec' not found. Is TensorRT / JetPack installed?" >&2
      exit 127
    fi
    [[ -z "${MODEL}" ]] && { echo "ERROR: --model=<path.onnx> required for orin" >&2; exit 2; }

    ENGINE_PATH="$(mktemp --suffix=.plan)"
    trap 'rm -f "${ENGINE_PATH}" "${SAMPLES_FILE}" "${EXTRA_JSON_FILE}"' EXIT

    echo "[${BENCH_ID}] building TensorRT engine (--${PRECISION})..."
    {
      echo "===== trtexec build ====="
      trtexec \
        --onnx="${MODEL}" \
        "--${PRECISION}" \
        --saveEngine="${ENGINE_PATH}" \
        --warmUp="${WARMUP}000" \
        2>&1
    } | tee -a "${RAW}" > /dev/null

    echo "[${BENCH_ID}] running inference (${ITERATIONS} iterations)..."
    {
      echo "===== trtexec inference ====="
      trtexec \
        --loadEngine="${ENGINE_PATH}" \
        --batch="${BATCH}" \
        --iterations="${ITERATIONS}" \
        --warmUp="${WARMUP}000" \
        --avgRuns=1 \
        2>&1
    } | tee -a "${RAW}" | \
      awk -v sf="${SAMPLES_FILE}" -v ej="${EXTRA_JSON_FILE}" '
        /\[I\] mean:/ {
          for (i = 1; i <= NF; i++) if ($i == "mean:") { lat = $(i+1); break }
        }
        /\[I\] Throughput:/ {
          for (i = 1; i <= NF; i++) if ($i == "Throughput:") { tput = $(i+1); break }
        }
        END {
          if (lat  != "") print lat  > sf
          printf "{\"throughput_qps\":%s}\n", (tput != "" ? tput : "null") > ej
        }
      '
    ;;

  s100)
    if ! command -v hb_perf >/dev/null 2>&1; then
      echo "ERROR: 'hb_perf' not found. Is HBDK / Compass SDK installed?" >&2
      exit 127
    fi
    [[ -z "${MODEL}" ]] && { echo "ERROR: --model=<path.bin> required for s100" >&2; exit 2; }

    echo "[${BENCH_ID}] running hb_perf on ${MODEL}..."
    {
      echo "===== hb_perf ====="
      hb_perf "${MODEL}" --batch "${BATCH}" 2>&1
    } | tee -a "${RAW}" | \
      awk -v sf="${SAMPLES_FILE}" -v ej="${EXTRA_JSON_FILE}" '
        /latency/ && /ms/ {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { lat = $i; break }
          }
        }
        /throughput/ && /fps/ {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { tput = $i; break }
          }
        }
        END {
          if (lat  != "") print lat  > sf
          printf "{\"throughput_fps\":%s}\n", (tput != "" ? tput : "null") > ej
        }
      '
    ;;

  *)
    # Generic fallback: onnxruntime CPU (useful on x86 or when no vendor SDK present).
    if ! python3 -c "import onnxruntime" 2>/dev/null; then
      echo "ERROR: onnxruntime not installed. Install with: pip install onnxruntime" >&2
      exit 127
    fi
    [[ -z "${MODEL}" ]] && { echo "ERROR: --model=<path.onnx> required" >&2; exit 2; }

    echo "[${BENCH_ID}] running onnxruntime CPU on ${MODEL} (${ITERATIONS} iters)..."
    {
      echo "===== onnxruntime CPU ====="
      PT_MODEL="${MODEL}" \
      PT_BATCH="${BATCH}" \
      PT_ITERS="${ITERATIONS}" \
      PT_WARMUP="${WARMUP}" \
      PT_SF="${SAMPLES_FILE}" \
      python3 - <<'PYORT'
import os, time
import numpy as np
import onnxruntime as ort

sess = ort.InferenceSession(
    os.environ["PT_MODEL"], providers=["CPUExecutionProvider"]
)
inp = sess.get_inputs()[0]
batch = int(os.environ["PT_BATCH"])
shape = [
    batch if (d in (None, -1) or str(d) == "batch_size") else int(d)
    for d in inp.shape
]
dummy = np.random.randn(*shape).astype(np.float32)

for _ in range(int(os.environ["PT_WARMUP"])):
    sess.run(None, {inp.name: dummy})

with open(os.environ["PT_SF"], "w") as sf:
    for _ in range(int(os.environ["PT_ITERS"])):
        t0 = time.perf_counter_ns()
        sess.run(None, {inp.name: dummy})
        lat_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        sf.write(f"{lat_ms}\n")
PYORT
    } | tee -a "${RAW}" > /dev/null
    ;;
esac

if [[ ! -s "${SAMPLES_FILE}" ]]; then
  echo "ERROR: no latency samples collected. See ${RAW}" >&2
  exit 1
fi

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_MODEL="${MODEL}" \
PT_BATCH="${BATCH}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP="${WARMUP}" \
PT_PRECISION="${PRECISION}" \
PT_SAMPLES_FILE="${SAMPLES_FILE}" \
PT_EXTRA_JSON="${EXTRA_JSON_FILE}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket


def env(k, cast=str):
    return cast(os.environ[k])


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

extra = {}
try:
    with open(env("PT_EXTRA_JSON")) as f:
        extra = json.load(f)
except Exception:
    pass

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


# Orin trtexec reports latency in µs; hb_perf and onnxruntime report in ms.
lat_unit = "us" if env("PT_PLATFORM") == "orin" else "ms"
avg_lat = statistics.fmean(samples)

metrics: dict = {
    "inference_latency": {
        "p50":   pct(50),
        "p95":   pct(95),
        "p99":   pct(99),
        "min":   min(samples),
        "max":   max(samples),
        "avg":   avg_lat,
        "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "unit":  lat_unit,
    }
}

# Pass through any direct throughput measurements from the tool.
for k, v in extra.items():
    if v is not None:
        metrics[k] = {
            "avg":  float(v),
            "unit": "fps" if "fps" in k else "qps",
        }

# Derive single-sample throughput from average latency as a fallback.
if avg_lat > 0:
    div = 1_000.0 if lat_unit == "ms" else 1_000_000.0
    metrics["throughput_fps_derived"] = {
        "avg":  (div / avg_lat) * int(env("PT_BATCH")),
        "unit": "fps",
    }

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "model":      env("PT_MODEL"),
        "batch_size": int(env("PT_BATCH")),
        "iterations": int(env("PT_ITERATIONS")),
        "warmup":     int(env("PT_WARMUP")),
        "precision":  env("PT_PRECISION"),
    },
    "metrics":    metrics,
    "raw_samples": samples,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   0,
    "notes": (
        f"platform={env('PT_PLATFORM')} precision={env('PT_PRECISION')}. "
        "Orin: trtexec mean latency (us); S100: hb_perf latency (ms); "
        "x86/fallback: onnxruntime per-inference wall time (ms)."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
