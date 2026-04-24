#!/usr/bin/env bash
# profile.sh — Interactive ROS 2 application profiler
#
# Attach to any running ROS 2 process, collect CPU%, memory, threads, I/O and
# optional flame-graph data while you manually trigger different application
# states (feature on / off, different parameters, etc.).  Stop with 'q' to
# get a self-contained HTML report comparing every named state.
#
# Usage:
#   ./benchmarks/ros2/app-profiler/profile.sh \
#       [--pid=PID | --process=NAME | --ros-node=NODE_NAME] \
#       --session=NAME \
#       [--platform=ID]            (default: hostname)
#       [--interval-ms=500]        (sampling interval, default 500 ms)
#       [--out-dir=results]        (default: <repo-root>/results)
#       [--flamegraph]             (enable perf + FlameGraph SVG)
#       [--flamegraph-dir=PATH]    (default: ~/FlameGraph)
#       [--perf-freq=99]           (perf sampling frequency Hz)
#
# Interactive commands during a session:
#   m <label>   Mark the current time with a state label
#               e.g.:  m baseline    m feature_on    m feature_off
#   s           Print the most recent resource snapshot
#   q           Stop monitoring and generate the HTML report
#
# Examples:
#   # Profile by process name
#   ./profile.sh --process=my_ros2_node --session=feature-ab-test
#
#   # Profile by PID with flame graph
#   ./profile.sh --pid=12345 --session=load-test --flamegraph
#
#   # Profile a ROS 2 node by name (searches cmdline)
#   ./profile.sh --ros-node=/perception/detector --session=detector-bench
#
# Requirements:
#   python3 (stdlib only), pgrep
#   For flame graphs: perf  +  git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Walk up to the repo root, identified by the presence of a .git directory.
# Expected layout: <root>/benchmarks/ros2/app-profiler/profile.sh
_find_root() {
  local dir="$1"
  while [[ "${dir}" != "/" ]]; do
    [[ -d "${dir}/.git" ]] && { echo "${dir}"; return 0; }
    dir="$(dirname "${dir}")"
  done
  # Fallback: four levels up (original assumption) with a clear comment.
  # benchmarks/ros2/app-profiler/ is three levels below the repo root.
  echo "$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
}
ROOT="$(_find_root "${SCRIPT_DIR}")"

# ── Argument defaults ─────────────────────────────────────────────────────────
TARGET_PID=""
PROCESS_NAME=""
ROS_NODE_NAME=""
SESSION_NAME=""
PLATFORM="${PLATFORM_ID:-$(hostname -s 2>/dev/null || hostname)}"
INTERVAL_MS=500
OUT_DIR="${ROOT}/results"
USE_FLAMEGRAPH=false
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-${HOME}/FlameGraph}"
PERF_FREQ=99

for _arg in "$@"; do
  case "${_arg}" in
    --pid=*)            TARGET_PID="${_arg#*=}" ;;
    --process=*)        PROCESS_NAME="${_arg#*=}" ;;
    --ros-node=*)       ROS_NODE_NAME="${_arg#*=}" ;;
    --session=*)        SESSION_NAME="${_arg#*=}" ;;
    --platform=*)       PLATFORM="${_arg#*=}" ;;
    --interval-ms=*)    INTERVAL_MS="${_arg#*=}" ;;
    --out-dir=*)        OUT_DIR="${_arg#*=}" ;;
    --flamegraph)       USE_FLAMEGRAPH=true ;;
    --flamegraph-dir=*) FLAMEGRAPH_DIR="${_arg#*=}" ;;
    --perf-freq=*)      PERF_FREQ="${_arg#*=}" ;;
    -h|--help)          sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown argument: ${_arg}" >&2; exit 2 ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "${SESSION_NAME}" ]]; then
  echo "ERROR: --session=<name> is required" >&2; exit 2
fi
if [[ -z "${TARGET_PID}" && -z "${PROCESS_NAME}" && -z "${ROS_NODE_NAME}" ]]; then
  echo "ERROR: one of --pid, --process, or --ros-node is required" >&2; exit 2
fi

# ── Terminal colours ──────────────────────────────────────────────────────────
C0="\033[0m"; CBOLD="\033[1m"
CGR="\033[32m"; CCY="\033[36m"; CYL="\033[33m"; CRD="\033[31m"
_info()  { echo -e "${CGR}[✓]${C0} $*"; }
_warn()  { echo -e "${CYL}[!]${C0} $*"; }
_step()  { echo -e "${CCY}[→]${C0} $*"; }
_err()   { echo -e "${CRD}[✗]${C0} $*" >&2; }

# ── Resolve PID ───────────────────────────────────────────────────────────────
if [[ -z "${TARGET_PID}" ]]; then
  _SEARCH="${PROCESS_NAME:-${ROS_NODE_NAME}}"
  _step "Searching for process matching '${_SEARCH}'..."
  _FOUND="$(pgrep -f "${_SEARCH}" 2>/dev/null | head -5 || true)"
  if [[ -z "${_FOUND}" ]]; then
    _err "No running process matches '${_SEARCH}'"
    exit 1
  fi
  _COUNT="$(echo "${_FOUND}" | wc -l)"
  if (( _COUNT > 1 )); then
    _warn "Multiple matches: $(echo "${_FOUND}" | tr '\n' ' ')"
    _warn "Using first PID. Pass --pid=<pid> to be explicit."
  fi
  TARGET_PID="$(echo "${_FOUND}" | head -1)"
fi

if ! kill -0 "${TARGET_PID}" 2>/dev/null; then
  _err "PID ${TARGET_PID} is not running"
  exit 1
fi

PROCESS_COMM="$(cat "/proc/${TARGET_PID}/comm" 2>/dev/null || echo "unknown")"

# ── Create session directory ──────────────────────────────────────────────────
SESSION_ID="${SESSION_NAME}_$(date -u +%Y-%m-%dT%H-%M-%SZ)"
SESSION_DIR="${OUT_DIR}/${PLATFORM}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}"
STATES_FILE="${SESSION_DIR}/states.jsonl"
METRICS_FILE="${SESSION_DIR}/metrics.jsonl"
LOG_FILE="${SESSION_DIR}/profile.log"
PERF_DATA="${SESSION_DIR}/perf.data"
: > "${STATES_FILE}"; : > "${METRICS_FILE}"; : > "${LOG_FILE}"

# ── State-marker helper ───────────────────────────────────────────────────────
_SESSION_T0="$(python3 -c 'import time; print(time.time())')"

_mark() {
  local _label="$1"
  local _ts _rel
  _ts="$(python3 -c 'import time; print(time.time())')"
  _rel="$(python3 -c "print(round(${_ts} - ${_SESSION_T0}, 3))")"
  python3 -c "import json; print(json.dumps({'t': ${_ts}, 'label': '${_label}', 't_rel': ${_rel}}))" \
    >> "${STATES_FILE}"
  _info "State marked: '${_label}'  (t+${_rel}s)"
}

# ── Environment snapshot ──────────────────────────────────────────────────────
_step "Collecting environment snapshot..."
_SNAP_TMP="$(mktemp -d)"
_SNAP_RUN="$("${ROOT}/scripts/env-snapshot.sh" \
  --platform="${PLATFORM}" --out-dir="${_SNAP_TMP}" 2>>"${LOG_FILE}" || true)"
if [[ -n "${_SNAP_RUN}" && -f "${_SNAP_RUN}/env.json" ]]; then
  cp "${_SNAP_RUN}/env.json" "${SESSION_DIR}/env.json"
fi
rm -rf "${_SNAP_TMP}"

# ── Start monitor.py ─────────────────────────────────────────────────────────
_step "Starting resource monitor (interval=${INTERVAL_MS} ms)..."
python3 "${SCRIPT_DIR}/monitor.py" \
  --pid="${TARGET_PID}" \
  --out-dir="${SESSION_DIR}" \
  --interval-ms="${INTERVAL_MS}" \
  >>"${LOG_FILE}" 2>&1 &
MONITOR_BGPID=$!
sleep 0.4
if ! kill -0 "${MONITOR_BGPID}" 2>/dev/null; then
  _err "monitor.py failed to start — see ${LOG_FILE}"; exit 1
fi
_info "Monitor started (PID=${MONITOR_BGPID})"

# ── Start perf record (optional) ─────────────────────────────────────────────
PERF_BGPID=""
if [[ "${USE_FLAMEGRAPH}" == "true" ]]; then
  if ! command -v perf &>/dev/null; then
    _warn "'perf' not found — flame graph disabled"
    _warn "Install: sudo apt-get install linux-perf"
    USE_FLAMEGRAPH=false
  elif [[ ! -x "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" ]]; then
    _warn "FlameGraph scripts not found at '${FLAMEGRAPH_DIR}' — flame graph disabled"
    _warn "Install: git clone https://github.com/brendangregg/FlameGraph '${FLAMEGRAPH_DIR}'"
    USE_FLAMEGRAPH=false
  else
    _PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)"
    if (( _PARANOID > 1 )); then
      _warn "perf_event_paranoid=${_PARANOID}; if perf fails run:"
      _warn "  sudo sysctl -w kernel.perf_event_paranoid=1"
    fi
    perf record -F "${PERF_FREQ}" -g --call-graph dwarf \
      -p "${TARGET_PID}" -o "${PERF_DATA}" >>"${LOG_FILE}" 2>&1 &
    PERF_BGPID=$!
    _info "perf record started (PID=${PERF_BGPID}, freq=${PERF_FREQ} Hz)"
  fi
fi

# ── Cleanup — called once at exit ─────────────────────────────────────────────
_CLEANUP_DONE=false
_do_cleanup() {
  [[ "${_CLEANUP_DONE}" == "true" ]] && return 0
  _CLEANUP_DONE=true

  echo ""
  _step "Stopping monitors..."

  kill "${MONITOR_BGPID}" 2>/dev/null || true
  wait "${MONITOR_BGPID}" 2>/dev/null || true

  if [[ -n "${PERF_BGPID}" ]] && kill -0 "${PERF_BGPID}" 2>/dev/null; then
    kill -INT "${PERF_BGPID}" 2>/dev/null || true
    wait "${PERF_BGPID}" 2>/dev/null || true
    sleep 0.5   # give perf time to flush
  fi

  # ── Flame graph ──
  if [[ "${USE_FLAMEGRAPH}" == "true" && -f "${PERF_DATA}" ]]; then
    _step "Generating flame graph..."
    if perf script -i "${PERF_DATA}" 2>>"${LOG_FILE}" \
        | "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" 2>>"${LOG_FILE}" \
        | "${FLAMEGRAPH_DIR}/flamegraph.pl" \
        > "${SESSION_DIR}/flamegraph.svg" 2>>"${LOG_FILE}"; then
      _info "Flame graph: ${SESSION_DIR}/flamegraph.svg"
    else
      _warn "Flame graph generation failed — see ${LOG_FILE}"
      rm -f "${SESSION_DIR}/flamegraph.svg"
    fi
  fi

  # ── Summary JSON (schema v1) ──
  _step "Computing statistics..."
  export PT_SESSION="${SESSION_NAME}"
  export PT_PLATFORM="${PLATFORM}"
  export PT_TARGET_PID="${TARGET_PID}"
  export PT_PROCESS_COMM="${PROCESS_COMM}"
  export PT_INTERVAL_MS="${INTERVAL_MS}"
  export PT_USE_FLAMEGRAPH="${USE_FLAMEGRAPH}"
  export PT_METRICS_FILE="${METRICS_FILE}"
  export PT_JSON_OUT="${SESSION_DIR}/ros2.app-profiler.json"

  python3 - <<'_PYSUMMARY'
import json, datetime, socket, os, statistics
from pathlib import Path

def _env(k): return os.environ.get(k, "")

samples = []
with open(_env("PT_METRICS_FILE")) as fh:
    for line in fh:
        line = line.strip()
        if line:
            try: samples.append(json.loads(line))
            except: pass

def _stat(vals):
    if not vals:
        return {"p50": None, "p95": None, "avg": None, "max": None, "min": None, "stdev": None}
    s = sorted(vals)
    def pct(p):
        if len(s) == 1: return s[0]
        k = (len(s) - 1) * (p / 100.0); lo = int(k); hi = min(lo+1, len(s)-1)
        return round(s[lo] + (s[hi]-s[lo]) * (k-lo), 3)
    return {"p50": pct(50), "p95": pct(95),
            "avg": round(statistics.fmean(vals), 3),
            "max": round(max(vals), 3), "min": round(min(vals), 3),
            "stdev": round(statistics.pstdev(vals) if len(vals) > 1 else 0, 3)}

cpu = [s["cpu_pct"] for s in samples if "cpu_pct" in s]
rss = [s["rss_mb"]  for s in samples if "rss_mb"  in s]
thr = [float(s["threads"]) for s in samples if "threads" in s]

doc = {
    "schema_version": "1",
    "benchmark":  "ros2.app-profiler",
    "platform":   _env("PT_PLATFORM"),
    "timestamp":  datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host":       socket.gethostname(),
    "env_ref":    "env.json",
    "params": {
        "session":          _env("PT_SESSION"),
        "target_pid":       int(_env("PT_TARGET_PID")),
        "target_comm":      _env("PT_PROCESS_COMM"),
        "interval_ms":      int(_env("PT_INTERVAL_MS")),
        "flamegraph_enabled": _env("PT_USE_FLAMEGRAPH").lower() == "true",
    },
    "metrics": {
        "cpu_pct": {**_stat(cpu), "unit": "%"},
        "rss_mb":  {**_stat(rss), "unit": "MB"},
        "threads": {**_stat(thr), "unit": "count"},
    },
    "sample_count": len(samples),
    "notes": "",
}
with open(_env("PT_JSON_OUT"), "w") as fh:
    json.dump(doc, fh, indent=2)
print(f"Summary JSON: {_env('PT_JSON_OUT')}")
_PYSUMMARY

  # ── HTML report ──
  _step "Generating HTML report..."
  if python3 "${SCRIPT_DIR}/gen-report.py" \
      --session-dir="${SESSION_DIR}" \
      --session-name="${SESSION_NAME}" \
      --process="${PROCESS_COMM}" \
      --pid="${TARGET_PID}" \
      >>"${LOG_FILE}" 2>&1; then
    _REPORT_PATH="${SESSION_DIR}/report.html"
    echo ""
    echo -e "${CBOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
    _info "Report: ${_REPORT_PATH}"
    _info "Data:   ${SESSION_DIR}/"
    echo -e "${CBOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
  else
    _warn "Report generation failed — see ${LOG_FILE}"
    _info "Raw data saved to: ${SESSION_DIR}/"
  fi
}

trap '_mark "session_end" 2>/dev/null; _do_cleanup' INT TERM

# ── Welcome banner ────────────────────────────────────────────────────────────
echo ""
echo -e "${CBOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
echo -e "${CBOLD}  🔥 ROS 2 App Profiler${C0}"
echo -e "${CBOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C0}"
_info "Session:  ${SESSION_NAME}"
_info "Process:  ${PROCESS_COMM}  (PID ${TARGET_PID})"
_info "Platform: ${PLATFORM}"
_info "Interval: ${INTERVAL_MS} ms"
_info "Output:   ${SESSION_DIR}"
[[ "${USE_FLAMEGRAPH}" == "true" ]] && _info "FlameGraph: enabled"
echo ""
echo "  m <label>   mark a state   (e.g.:  m baseline  /  m feature_on)"
echo "  s           show live stats"
echo "  q           stop and generate report"
echo ""

_mark "session_start"

# ── Live stats helper ─────────────────────────────────────────────────────────
_show_status() {
  local _last
  _last="$(tail -1 "${METRICS_FILE}" 2>/dev/null || true)"
  if [[ -z "${_last}" ]]; then
    echo "  (no samples yet — check that the process is still running)"
    return
  fi
  PT_LAST_SAMPLE="${_last}" python3 - <<'_PYSTATS'
import json, os
try:
    s = json.loads(os.environ['PT_LAST_SAMPLE'])
    cpu = s.get('cpu_pct', 0)
    rss = s.get('rss_mb', 0)
    thr = s.get('threads', 0)
    ior = s.get('io_read_kb', 0)
    iow = s.get('io_write_kb', 0)
    fds = s.get('fd_count', '?')
    print(f"  CPU {cpu:.1f}%   RSS {rss:.1f} MB   Threads {thr}"
          f"   IO r/w {ior:.1f}/{iow:.1f} KB   FDs {fds}")
except Exception as e:
    print(f"  (parse error: {e})")
_PYSTATS
}

# ── Interactive REPL ──────────────────────────────────────────────────────────
set +e
while true; do
  printf "> "
  if ! IFS= read -r _CMD 2>/dev/null; then
    break   # EOF (Ctrl-D)
  fi
  case "${_CMD}" in
    q|quit|exit)      break ;;
    s|status|stats)   _show_status ;;
    m\ *|mark\ *)     _mark "${_CMD#* }" ;;
    "")               : ;;
    *)                echo "  Commands:  m <label>  |  s  |  q" ;;
  esac
done

_mark "session_end" 2>/dev/null || true
_do_cleanup
