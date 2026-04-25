#!/usr/bin/env bash
# benchmarks/system/power-thermal/run.sh — power & thermal sampling under CPU load.
#
# Starts a stress workload for --duration seconds, then samples power draw and
# die temperature every --interval seconds via platform-specific tools.
#
# Platform dispatch:
#   orin   — tegrastats (JetPack)
#   s100   — hrut_soc / hrut_power (Horizon RDK SDK)
#   *      — /sys/class/thermal + powerstat (best-effort)
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--duration=300] [--interval=5]
#            [--stress-cmd="stress-ng --cpu 0 --timeout 300s"]
#
# Requires: stress-ng or stress (CPU load); platform telemetry tool.
#
# Writes: <run-dir>/system.power_thermal.json       (schema: docs/result-schema.md)
#         <run-dir>/system.power_thermal.raw.txt
#         <run-dir>/system.power_thermal.samples.tsv
set -euo pipefail

BENCH_ID="system.power_thermal"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
DURATION_S="300"
INTERVAL_S="5"
STRESS_CMD=""

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --duration=*)   DURATION_S="${arg#*=}" ;;
    --interval=*)   INTERVAL_S="${arg#*=}" ;;
    --stress-cmd=*) STRESS_CMD="${arg#*=}" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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
SAMPLES_TSV="${RUN_DIR}/${BENCH_ID}.samples.tsv"
: > "${RAW}"

printf "timestamp_s\tpower_w\ttemp_c\n" > "${SAMPLES_TSV}"

safe() { "$@" 2>/dev/null || true; }

echo "[${BENCH_ID}] platform=${PLATFORM} duration=${DURATION_S}s interval=${INTERVAL_S}s"

# ─── stress workload ─────────────────────────────────────────────────────────
if [[ -z "${STRESS_CMD}" ]]; then
  if command -v stress-ng >/dev/null 2>&1; then
    STRESS_CMD="stress-ng --cpu 0 --timeout ${DURATION_S}s"
  elif command -v stress >/dev/null 2>&1; then
    STRESS_CMD="stress --cpu $(nproc) --timeout ${DURATION_S}s"
  else
    echo "WARN: neither stress-ng nor stress found; sampling idle power." >&2
    STRESS_CMD="sleep ${DURATION_S}"
  fi
fi

eval "${STRESS_CMD}" &
STRESS_PID=$!
echo "[${BENCH_ID}] stress PID=${STRESS_PID}"

cleanup() {
  kill "${STRESS_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ─── sampling loop ────────────────────────────────────────────────────────────
START_EPOCH="$(date +%s)"
SAMPLE_COUNT=0

while kill -0 "${STRESS_PID}" 2>/dev/null; do
  NOW_EPOCH="$(date +%s)"
  ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
  POWER_W=""
  TEMP_C=""

  case "${PLATFORM}" in
    orin)
      TSTAT="$(safe timeout 2 tegrastats --interval 1000 | head -n 1)"
      # VDD_IN is total board power in mW; field looks like "VDD_IN 5000mW/5200mW"
      POWER_W="$(printf '%s\n' "${TSTAT}" | \
        grep -oP 'VDD_IN \K[0-9]+(?=mW)' | \
        awk '{print $1/1000}' 2>/dev/null || true)"
      TEMP_C="$(printf '%s\n' "${TSTAT}" | \
        grep -oP 'CPU@\K[0-9.]+(?=C)' | head -n1 || true)"
      printf '%s\n' "${TSTAT}" >> "${RAW}"
      ;;
    s100)
      # Horizon RDK SDK tools; exact output format depends on BSP version.
      SOC="$(safe hrut_soc 2>/dev/null || safe hrut_power 2>/dev/null || true)"
      POWER_W="$(printf '%s\n' "${SOC}" | \
        grep -oiP 'power\s*[=:]\s*\K[0-9.]+' | head -n1 || true)"
      TEMP_C="$(printf '%s\n' "${SOC}" | \
        grep -oiP 'temp\s*[=:]\s*\K[0-9.]+' | head -n1 || true)"
      printf '%s\n' "${SOC}" >> "${RAW}"
      ;;
    *)
      TEMP_RAW="$(safe cat /sys/class/thermal/thermal_zone0/temp)"
      if [[ -n "${TEMP_RAW}" ]]; then
        TEMP_C="$(awk "BEGIN{printf \"%.1f\", ${TEMP_RAW}/1000}")"
      fi
      if command -v powerstat >/dev/null 2>&1; then
        POWER_W="$(safe timeout 4 powerstat -d 1 1 2>/dev/null | \
          awk '/^Average/{for(i=1;i<=NF;i++) if($i=="W") print $(i-1)}' | \
          head -n1 || true)"
      fi
      ;;
  esac

  printf '%d\t%s\t%s\n' "${ELAPSED}" "${POWER_W}" "${TEMP_C}" >> "${SAMPLES_TSV}"
  (( SAMPLE_COUNT++ )) || true
  sleep "${INTERVAL_S}"
done

wait "${STRESS_PID}" 2>/dev/null || true
echo "[${BENCH_ID}] collected ${SAMPLE_COUNT} samples."

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_DURATION_S="${DURATION_S}" \
PT_INTERVAL_S="${INTERVAL_S}" \
PT_STRESS_CMD="${STRESS_CMD}" \
PT_SAMPLES_TSV="${SAMPLES_TSV}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket


def env(k):
    return os.environ[k]


rows = []
with open(env("PT_SAMPLES_TSV")) as fh:
    for i, line in enumerate(fh):
        if i == 0:          # skip header
            continue
        parts = line.strip().split("\t")
        if len(parts) < 3:
            continue
        try:
            t = float(parts[0])
            p = float(parts[1]) if parts[1].strip() else None
            c = float(parts[2]) if parts[2].strip() else None
            rows.append((t, p, c))
        except ValueError:
            pass


def _stat(values, unit):
    vs = sorted(v for v in values if v is not None)
    if not vs:
        return None

    def pct(p):
        if len(vs) == 1:
            return vs[0]
        k = (len(vs) - 1) * (p / 100.0)
        f = int(k)
        c = min(f + 1, len(vs) - 1)
        if f == c:
            return vs[f]
        return vs[f] + (vs[c] - vs[f]) * (k - f)

    return {
        "p50":   pct(50),
        "p95":   pct(95),
        "p99":   pct(99),
        "min":   min(vs),
        "max":   max(vs),
        "avg":   statistics.fmean(vs),
        "stdev": statistics.pstdev(vs) if len(vs) > 1 else 0.0,
        "peak":  max(vs),
        "unit":  unit,
        "count": len(vs),
    }


metrics: dict = {}
pm = _stat([r[1] for r in rows], "W")
tm = _stat([r[2] for r in rows], "C")
if pm:
    metrics["power_w"] = pm
if tm:
    metrics["temp_c"] = tm

if not metrics:
    raise SystemExit(
        "no power/thermal samples parsed — "
        "check raw output and platform tool availability"
    )

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "duration_s":  int(env("PT_DURATION_S")),
        "interval_s":  int(env("PT_INTERVAL_S")),
        "stress_cmd":  env("PT_STRESS_CMD"),
    },
    "metrics": metrics,
    "raw_samples": [
        {"t_s": r[0], "power_w": r[1], "temp_c": r[2]} for r in rows
    ],
    "iterations": len(rows),
    "warmup_s":   0,
    "notes": (
        "Samples taken while stress load is active. "
        "power_w: platform total board power (Orin: VDD_IN, S100: hrut_power). "
        "temp_c: primary CPU thermal zone."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
