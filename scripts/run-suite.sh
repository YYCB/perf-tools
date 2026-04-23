#!/usr/bin/env bash
# run-suite.sh — orchestrate a set of benchmarks for one platform
#
# Usage:
#   ./scripts/run-suite.sh --platform=orin [--suite=quick|full] [--out-dir=results]
#
# Suites:
#   quick  - sysbench CPU only (M1 minimum loop)
#   full   - all available benchmarks (M2+)
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
for arg in "$@"; do
  case "$arg" in
    --platform=*) PLATFORM="${arg#*=}" ;;
    --suite=*)    SUITE="${arg#*=}" ;;
    --out-dir=*)  OUT_DIR="${arg#*=}" ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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
  full)
    # Discover every executable run.sh under benchmarks/, in deterministic order.
    mapfile -t BENCHMARKS < <(find "${ROOT}/benchmarks" -type f -name 'run.sh' -perm -u+x | sort)
    ;;
  *)
    echo "ERROR: unknown suite '${SUITE}' (use quick|full)" >&2
    exit 2
    ;;
esac

# --- Step 3: run each benchmark ---
PASS=0; FAIL=0
for bench in "${BENCHMARKS[@]}"; do
  if [[ ! -x "${bench}" ]]; then
    echo "[suite] SKIP (not executable): ${bench}"
    continue
  fi
  echo "[suite] >>> ${bench#${ROOT}/}"
  if "${bench}" --platform="${PLATFORM}" --run-dir="${RUN_DIR}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    echo "[suite] FAIL (rc=${rc}): ${bench#${ROOT}/}" >&2
    FAIL=$((FAIL+1))
  fi
done

echo "[suite] done. pass=${PASS} fail=${FAIL} run_dir=${RUN_DIR}"
echo "${RUN_DIR}"
[[ ${FAIL} -eq 0 ]]
