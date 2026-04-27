#!/usr/bin/env bash
# benchmarks/system/network/run.sh — loopback network throughput & latency.
#
# Tool priority (first found wins):
#   iperf3    — TCP bulk throughput (Gbps) via loopback.
#   sockperf  — UDP round-trip latency (µs) via loopback.
#   python3   — pure-Python TCP loopback bandwidth (conservative lower bound).
#
# Install hints:
#   apt-get install -y iperf3
#   apt-get install -y sockperf
#
# Usage:
#   ./run.sh --platform=orin [--run-dir=<dir>]
#            [--duration=10] [--iterations=5] [--warmup=2]
#
# Writes: <run-dir>/system.network.json  (schema: docs/result-schema.md)
#         <run-dir>/system.network.raw.txt
set -euo pipefail

BENCH_ID="system.network"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PLATFORM=""
RUN_DIR=""
DURATION_S="10"
ITERATIONS="5"
WARMUP="2"

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --run-dir=*)    RUN_DIR="${arg#*=}" ;;
    --duration=*)   DURATION_S="${arg#*=}" ;;
    --iterations=*) ITERATIONS="${arg#*=}" ;;
    --warmup=*)     WARMUP="${arg#*=}" ;;
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
SAMPLES_BW="${RUN_DIR}/${BENCH_ID}.bw.samples"
SAMPLES_LAT="${RUN_DIR}/${BENCH_ID}.lat.samples"

: > "${RAW}"
: > "${SAMPLES_BW}"
: > "${SAMPLES_LAT}"
TOOL_USED=""

# ─── iperf3 throughput (loopback) ────────────────────────────────────────────
if command -v iperf3 &>/dev/null; then
  TOOL_USED="iperf3"
  echo "[${BENCH_ID}] tool: iperf3" | tee -a "${RAW}"

  # Start server in background, kill on exit
  iperf3 -s -D --pidfile /tmp/perf-tools-iperf3.pid 2>>"${RAW}" || true
  sleep 0.5
  trap 'kill "$(cat /tmp/perf-tools-iperf3.pid 2>/dev/null)" 2>/dev/null; rm -f /tmp/perf-tools-iperf3.pid' EXIT

  for (( i=0; i<WARMUP+ITERATIONS; i++ )); do
    OUT="$(iperf3 -c 127.0.0.1 -t "${DURATION_S}" -J 2>>"${RAW}")"
    BPS="$(echo "${OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['end']['sum_received']['bits_per_second'])" 2>/dev/null || echo "")"
    echo "${OUT}" >> "${RAW}"
    if [[ -z "${BPS}" ]]; then
      echo "[${BENCH_ID}] WARN: could not parse iperf3 output for iteration ${i}" | tee -a "${RAW}"
      continue
    fi
    MBPS="$(python3 -c "print(${BPS} / 1e6)")"
    [[ ${i} -ge ${WARMUP} ]] && echo "${MBPS}" >> "${SAMPLES_BW}"
  done

  # sockperf latency (opportunistic, if available)
  if command -v sockperf &>/dev/null; then
    echo "[${BENCH_ID}] also measuring loopback latency with sockperf" | tee -a "${RAW}"
    sockperf server --tcp -p 11112 &
    SP_PID=$!
    sleep 0.3
    for (( i=0; i<WARMUP+ITERATIONS; i++ )); do
      LAT_LINE="$(sockperf ping-pong --tcp -p 11112 -t "${DURATION_S}" 2>>"${RAW}" \
                   | grep -oP 'avg latency\s*=\s*\K[0-9.]+' || true)"
      [[ -n "${LAT_LINE}" && ${i} -ge ${WARMUP} ]] && echo "${LAT_LINE}" >> "${SAMPLES_LAT}"
    done
    kill "${SP_PID}" 2>/dev/null || true
    wait "${SP_PID}" 2>/dev/null || true
  fi

# ─── sockperf only ───────────────────────────────────────────────────────────
elif command -v sockperf &>/dev/null; then
  TOOL_USED="sockperf"
  echo "[${BENCH_ID}] tool: sockperf (latency only)" | tee -a "${RAW}"

  sockperf server --tcp -p 11112 &
  SP_PID=$!
  trap 'kill "${SP_PID}" 2>/dev/null; wait "${SP_PID}" 2>/dev/null || true' EXIT
  sleep 0.3

  for (( i=0; i<WARMUP+ITERATIONS; i++ )); do
    LAT_LINE="$(sockperf ping-pong --tcp -p 11112 -t "${DURATION_S}" 2>>"${RAW}" \
                 | grep -oP 'avg latency\s*=\s*\K[0-9.]+' || true)"
    [[ -n "${LAT_LINE}" && ${i} -ge ${WARMUP} ]] && echo "${LAT_LINE}" >> "${SAMPLES_LAT}"
  done

# ─── Python TCP loopback bandwidth fallback ──────────────────────────────────
else
  TOOL_USED="python3"
  echo "[${BENCH_ID}] tool: python3 TCP loopback (fallback)" | tee -a "${RAW}"

  TOTAL="$((WARMUP+ITERATIONS))"
  python3 - "${TOTAL}" "${WARMUP}" "${SAMPLES_BW}" "${RAW}" <<'PYNET'
import socket, time, threading, sys

total_iters = int(sys.argv[1])
warmup      = int(sys.argv[2])
out_file    = sys.argv[3]
raw_file    = sys.argv[4]
CHUNK       = 1 << 20   # 1 MiB
SEND_MB     = 512

def server(srv_sock, ready, done, results):
    srv_sock.listen(1)
    ready.set()
    conn, _ = srv_sock.accept()
    total = 0
    with conn:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            total += len(data)
    results['received'] = total
    done.set()

for i in range(total_iters):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', 19876))
    ready = threading.Event()
    done  = threading.Event()
    res   = {}
    t = threading.Thread(target=server, args=(srv, ready, done, res), daemon=True)
    t.start()
    ready.wait()

    cli = socket.socket()
    cli.connect(('127.0.0.1', 19876))
    buf = b'\x00' * CHUNK
    sent = 0
    target = SEND_MB * 1 << 20
    t0 = time.perf_counter()
    while sent < target:
        n = cli.send(buf[:min(CHUNK, target - sent)])
        sent += n
    cli.close()
    done.wait()
    elapsed = time.perf_counter() - t0
    bw = (sent / elapsed) / (1 << 20)
    srv.close()
    with open(raw_file, 'a') as rf:
        rf.write(f"iter={i} bw={bw:.2f} MB/s\n")
    if i >= warmup:
        with open(out_file, 'a') as sf:
            sf.write(f"{bw:.4f}\n")
PYNET
fi

# ─── validate at least bandwidth or latency was collected ────────────────────
HAS_BW=false; HAS_LAT=false
[[ -s "${SAMPLES_BW}"  ]] && HAS_BW=true
[[ -s "${SAMPLES_LAT}" ]] && HAS_LAT=true

if ! ${HAS_BW} && ! ${HAS_LAT}; then
  echo "ERROR: no network samples collected. See ${RAW}" >&2
  exit 1
fi

# ─── aggregate to JSON ────────────────────────────────────────────────────────
PT_BENCH_ID="${BENCH_ID}" \
PT_PLATFORM="${PLATFORM}" \
PT_TOOL="${TOOL_USED}" \
PT_DURATION_S="${DURATION_S}" \
PT_ITERATIONS="${ITERATIONS}" \
PT_WARMUP="${WARMUP}" \
PT_SAMPLES_BW="${SAMPLES_BW}" \
PT_SAMPLES_LAT="${SAMPLES_LAT}" \
PT_HAS_BW="${HAS_BW}" \
PT_HAS_LAT="${HAS_LAT}" \
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
raw_bw, raw_lat = [], []

if env("PT_HAS_BW") == "true":
    raw_bw = load_samples(env("PT_SAMPLES_BW"))
    s = stats(raw_bw, "Mbit/s")
    if s:
        metrics["throughput"] = s

if env("PT_HAS_LAT") == "true":
    raw_lat = load_samples(env("PT_SAMPLES_LAT"))
    s = stats(raw_lat, "us")
    if s:
        metrics["rtt_avg_us"] = s

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
        "duration_s": int(env("PT_DURATION_S")),
        "iterations": int(env("PT_ITERATIONS")),
        "warmup":     int(env("PT_WARMUP")),
        "interface":  "loopback",
    },
    "metrics": metrics,
    "raw_samples": {"bw": raw_bw, "lat_us": raw_lat},
    "iterations": int(env("PT_ITERATIONS")),
    "warmup_s":   int(env("PT_WARMUP")),
    "notes": (
        "iperf3: TCP loopback throughput (Mbit/s). "
        "sockperf: UDP ping-pong RTT (µs). "
        "python3 fallback: TCP loopback memcpy bandwidth."
    ),
}

with open(env("PT_JSON_OUT"), "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"wrote {env('PT_JSON_OUT')}")
PY

echo "[${BENCH_ID}] done. result -> ${JSON_OUT}"
