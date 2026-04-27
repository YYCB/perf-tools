#!/usr/bin/env bash
# benchmarks/system/storage/run.sh — storage I/O benchmark.
#
# Tool priority (first found wins):
#   fio       — industry-standard flexible I/O tester.
#   python3   — pure-Python sequential write/read (conservative lower bound).
#
# Install hints:
#   apt-get install -y fio
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--size=512M] [--iterations=3] [--warmup=1]
#            [--work-dir=/tmp]
#
# Writes: <run-dir>/system.storage.json  (schema: docs/result-schema.md)
#         <run-dir>/system.storage.raw.txt
#
# WARNING: fio creates a temporary test file under --work-dir.  Ensure the
# target filesystem has enough free space (2× --size).
set -euo pipefail

BENCH_ID="system.storage"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
SIZE="512M"
ITERATIONS="3"
WARMUP="1"
WORK_DIR="/tmp"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --size=*)       SIZE="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
    --work-dir=*)   WORK_DIR="${arg#*=}" ;;
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
SAMPLES_SEQ_W="${RUN_DIR}/${BENCH_ID}.seqw.samples"
SAMPLES_SEQ_R="${RUN_DIR}/${BENCH_ID}.seqr.samples"
SAMPLES_RAND_W="${RUN_DIR}/${BENCH_ID}.randw.samples"
SAMPLES_RAND_R="${RUN_DIR}/${BENCH_ID}.randr.samples"

: > "${RAW}"
: > "${SAMPLES_SEQ_W}"
: > "${SAMPLES_SEQ_R}"
: > "${SAMPLES_RAND_W}"
: > "${SAMPLES_RAND_R}"

TOOL_USED=""
FIO_FILE="${WORK_DIR}/perf-tools-storage-test.tmp"
trap 'rm -f "${FIO_FILE}"' EXIT

# Helper: size string → bytes (supports K/M/G suffixes, case-insensitive)
size_to_bytes() {
  python3 - "$1" <<'PYEOF'
import sys, re
s = sys.argv[1].strip().upper()
m = re.fullmatch(r'(\d+(?:\.\d+)?)\s*([KMG]?)', s)
if not m:
    raise SystemExit(f"invalid size: {sys.argv[1]!r}")
val = float(m.group(1))
mul = {'K': 1024, 'M': 1024**2, 'G': 1024**3, '': 1}
print(int(val * mul[m.group(2)]))
PYEOF
}

# ─── fio ─────────────────────────────────────────────────────────────────────
if command -v fio &>/dev/null; then
  TOOL_USED="fio"
  echo "[${BENCH_ID}] tool: fio" | tee -a "${RAW}"

  TOTAL="$((WARMUP+ITERATIONS))"

  for (( i=0; i<TOTAL; i++ )); do
    # Sequential write
    BW="$(fio \
      --name=seqw --filename="${FIO_FILE}" \
      --rw=write --bs=1M --size="${SIZE}" \
      --numjobs=1 --iodepth=1 \
      --output-format=json \
      --ioengine=sync \
      2>>"${RAW}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['jobs'][0]['write']['bw'])  # KB/s
" 2>/dev/null || echo "")"
    if [[ -n "${BW}" ]] && [[ ${i} -ge ${WARMUP} ]]; then
      python3 -c "print(${BW}/1024.0)" >> "${SAMPLES_SEQ_W}"
    fi

    # Sequential read (file created by write above)
    BW="$(fio \
      --name=seqr --filename="${FIO_FILE}" \
      --rw=read --bs=1M --size="${SIZE}" \
      --numjobs=1 --iodepth=1 \
      --output-format=json \
      --ioengine=sync \
      2>>"${RAW}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['jobs'][0]['read']['bw'])
" 2>/dev/null || echo "")"
    if [[ -n "${BW}" ]] && [[ ${i} -ge ${WARMUP} ]]; then
      python3 -c "print(${BW}/1024.0)" >> "${SAMPLES_SEQ_R}"
    fi

    # Random write 4K
    IOPS="$(fio \
      --name=randw --filename="${FIO_FILE}" \
      --rw=randwrite --bs=4k --size="${SIZE}" \
      --numjobs=1 --iodepth=32 \
      --output-format=json \
      --ioengine=sync \
      2>>"${RAW}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['jobs'][0]['write']['iops'])
" 2>/dev/null || echo "")"
    [[ -n "${IOPS}" ]] && [[ ${i} -ge ${WARMUP} ]] && echo "${IOPS}" >> "${SAMPLES_RAND_W}"

    # Random read 4K
    IOPS="$(fio \
      --name=randr --filename="${FIO_FILE}" \
      --rw=randread --bs=4k --size="${SIZE}" \
      --numjobs=1 --iodepth=32 \
      --output-format=json \
      --ioengine=sync \
      2>>"${RAW}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['jobs'][0]['read']['iops'])
" 2>/dev/null || echo "")"
    [[ -n "${IOPS}" ]] && [[ ${i} -ge ${WARMUP} ]] && echo "${IOPS}" >> "${SAMPLES_RAND_R}"
  done

# ─── Python fallback ─────────────────────────────────────────────────────────
else
  TOOL_USED="python3"
  echo "[${BENCH_ID}] tool: python3 (fallback – sequential only)" | tee -a "${RAW}"

  TOTAL="$((WARMUP+ITERATIONS))"
  SIZE_BYTES="$(size_to_bytes "${SIZE}")"

  python3 - "${FIO_FILE}" "${TOTAL}" "${WARMUP}" \
             "${SIZE_BYTES}" "${SAMPLES_SEQ_W}" "${SAMPLES_SEQ_R}" "${RAW}" <<'PYSTORAGE'
import os, sys, time

fio_file   = sys.argv[1]
total      = int(sys.argv[2])
warmup     = int(sys.argv[3])
size_bytes = int(sys.argv[4])
sw_path    = sys.argv[5]
sr_path    = sys.argv[6]
raw_path   = sys.argv[7]
chunk      = 1 << 20  # 1 MiB

for i in range(total):
    # write
    buf = b'\x00' * chunk
    t0 = time.perf_counter()
    with open(fio_file, 'wb') as f:
        written = 0
        while written < size_bytes:
            n = min(chunk, size_bytes - written)
            f.write(buf[:n])
            written += n
        f.flush()
        os.fsync(f.fileno())
    elapsed_w = time.perf_counter() - t0
    bw_w = (size_bytes / elapsed_w) / (1 << 20)

    # read
    t0 = time.perf_counter()
    with open(fio_file, 'rb') as f:
        while True:
            data = f.read(chunk)
            if not data:
                break
    elapsed_r = time.perf_counter() - t0
    bw_r = (size_bytes / elapsed_r) / (1 << 20)

    with open(raw_path, 'a') as rf:
        rf.write(f"iter={i} write={bw_w:.2f} MB/s read={bw_r:.2f} MB/s\n")
    if i >= warmup:
        with open(sw_path, 'a') as sf:
            sf.write(f"{bw_w:.4f}\n")
        with open(sr_path, 'a') as sf:
            sf.write(f"{bw_r:.4f}\n")
PYSTORAGE
fi

# ─── validate ────────────────────────────────────────────────────────────────
if ! [[ -s "${SAMPLES_SEQ_W}" || -s "${SAMPLES_SEQ_R}" ]]; then
  echo "ERROR: no storage samples collected. See ${RAW}" >&2
  exit 1
fi

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_TOOL="${TOOL_USED}" \
PT_SIZE="${SIZE}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP="${WARMUP}" \
PT_SAMPLES_SEQ_W="${SAMPLES_SEQ_W}" \
PT_SAMPLES_SEQ_R="${SAMPLES_SEQ_R}" \
PT_SAMPLES_RAND_W="${SAMPLES_RAND_W}" \
PT_SAMPLES_RAND_R="${SAMPLES_RAND_R}" \
PT_JSON_OUT="${JSON_OUT}" \
python3 - <<'PY'
import json, os, statistics, datetime, socket


def env(k, cast=str):
    return cast(os.environ[k])


def load_samples(path):
    samples = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                samples.append(float(line))
            except ValueError:
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
        f = int(k)
        c = min(f + 1, len(ss) - 1)
        if f == c:
            return ss[f]
        return ss[f] + (ss[c] - ss[f]) * (k - f)

    return {
        "p50":   pct(50),
        "p95":   pct(95),
        "p99":   pct(99),
        "min":   min(samples),
        "max":   max(samples),
        "avg":   statistics.fmean(samples),
        "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "unit":  unit,
    }


metrics = {}
raw_all = {}

for key, path, unit in [
    ("seq_write_mb_s",  env("PT_SAMPLES_SEQ_W"),  "MB/s"),
    ("seq_read_mb_s",   env("PT_SAMPLES_SEQ_R"),  "MB/s"),
    ("rand_write_iops", env("PT_SAMPLES_RAND_W"), "IOPS"),
    ("rand_read_iops",  env("PT_SAMPLES_RAND_R"), "IOPS"),
]:
    if not os.path.exists(path):
        continue
    s = load_samples(path)
    if not s:
        continue
    raw_all[key] = s
    st = stats(s, unit)
    if st:
        metrics[key] = st

if not metrics:
    raise SystemExit("no metrics to write")

doc = {
    "schema_version": "1",
    "benchmark": env("PT_BENCH_ID"),
    "platform":  env("PT_PLATFORM"),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":      socket.gethostname(),
    "env_ref":   "env.json",
    "params": {
        "tool":       env("PT_TOOL"),
        "size":       env("PT_SIZE"),
        "iterations": int(env("PT_ITERATIONS")),
        "warmup":     int(env("PT_WARMUP")),
    },
    "metrics": metrics,
    "raw_samples": raw_all,
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   int(env("PT_WARMUP")),
    "notes": (
        "fio: seq rw 1M bs, rand rw 4K bs iodepth=32, ioengine=sync. "
        "python3 fallback: sequential only, buffered I/O with fsync."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
