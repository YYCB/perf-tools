#!/usr/bin/env bash
# run-suite.sh — orchestrate a set of benchmarks for one platform
#
# Usage:
#   ./scripts/run-suite.sh --platform=orin [--suite=quick|standard|full] \
#       [--out-dir=results] [--timeout=300] [--fail-fast]
#
# Suites:
#   quick    - sysbench CPU only (fast sanity check, no special hardware needed)
#   standard - hardware-agnostic set: cpu + memory + network + storage + pubsub
#              (runs on any Linux box, no GPU/NPU required)
#   full     - all available benchmarks (M2+, requires platform-specific hardware)
#
# Options:
#   --timeout=N   per-benchmark timeout in seconds (default: 600; 0 = unlimited)
#   --fail-fast   exit after the first benchmark failure (default: continue)
#
# This script:
#   1. calls env-snapshot.sh and captures the run directory
#   2. invokes each benchmark's run.sh, passing --run-dir=<dir>
#
# Each benchmark MUST accept --run-dir and write
#   <run-dir>/<benchmark-id>.json  (schema: docs/result-schema.md)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PLATFORM=""
SUITE="quick"
OUT_DIR="results"
TIMEOUT_S="600"
FAIL_FAST="false"

for arg in "$@"; do
  case "$arg" in
    --platform=*) PLATFORM="${arg#*=}" ;;
    --suite=*)    SUITE="${arg#*=}" ;;
    --out-dir=*)  OUT_DIR="${arg#*=}" ;;
    --timeout=*)  TIMEOUT_S="${arg#*=}" ;;
    --fail-fast)  FAIL_FAST="true" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  echo "ERROR: --platform=<id> is required" >&2
  exit 2
fi

# --- Step 1: env snapshot ---
RUN_DIR="$("${ROOT}/scripts/env-snapshot.sh" --platform="${PLATFORM}" --out-dir="${OUT_DIR}")"
echo "[suite] run dir: ${RUN_DIR}"

# --- Step 2: pick benchmarks ---
case "${SUITE}" in
  quick)
    BENCHMARKS=(
      "${ROOT}/benchmarks/system/cpu/sysbench/run.sh"
    )
    ;;
  standard)
    # Hardware-agnostic set.  Add run.sh paths here as more benchmarks are implemented.
    BENCHMARKS=()
    for candidate in \
      "${ROOT}/benchmarks/system/cpu/sysbench/run.sh" \
      "${ROOT}/benchmarks/system/memory/run.sh" \
      "${ROOT}/benchmarks/system/network/run.sh" \
      "${ROOT}/benchmarks/system/storage/run.sh" \
      "${ROOT}/benchmarks/ros2/pubsub-latency/run.sh"
    do
      [[ -x "${candidate}" ]] && BENCHMARKS+=("${candidate}")
    done
    ;;
  full)
    # Discover every executable run.sh under benchmarks/, in deterministic order.
    mapfile -t BENCHMARKS < <(find "${ROOT}/benchmarks" -type f -name 'run.sh' -perm -u+x | sort)
    ;;
  *)
    echo "ERROR: unknown suite '${SUITE}' (use quick|standard|full)" >&2
    exit 2
    ;;
esac

# --- Step 3: run each benchmark ---
PASS=0; FAIL=0; SKIP=0

_run_bench() {
  local bench="$1"
  if [[ "${TIMEOUT_S}" -gt 0 ]]; then
    timeout "${TIMEOUT_S}" "${bench}" --platform="${PLATFORM}" --run-dir="${RUN_DIR}"
  else
    "${bench}" --platform="${PLATFORM}" --run-dir="${RUN_DIR}"
  fi
}

for bench in "${BENCHMARKS[@]}"; do
  if [[ ! -x "${bench}" ]]; then
    echo "[suite] SKIP (not executable): ${bench}"
    SKIP=$((SKIP+1))
    continue
  fi
  echo "[suite] >>> ${bench#${ROOT}/}"
  if _run_bench "${bench}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    if [[ ${rc} -eq 124 ]]; then
      echo "[suite] TIMEOUT after ${TIMEOUT_S}s: ${bench#${ROOT}/}" >&2
    else
      echo "[suite] FAIL (rc=${rc}): ${bench#${ROOT}/}" >&2
    fi
    FAIL=$((FAIL+1))
    if [[ "${FAIL_FAST}" == "true" ]]; then
      echo "[suite] --fail-fast set, aborting." >&2
      break
    fi
  fi
done

echo "[suite] done. pass=${PASS} fail=${FAIL} skip=${SKIP} run_dir=${RUN_DIR}"
echo "${RUN_DIR}"
[[ ${FAIL} -eq 0 ]]
