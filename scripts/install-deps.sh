#!/usr/bin/env bash
# install-deps.sh — install all tool dependencies for perf-tools on Ubuntu/Debian.
#
# Usage:
#   sudo ./scripts/install-deps.sh [--ros-distro=humble] [--skip-ros]
#
# What this installs:
#   System benchmarks:  sysbench, fio, iperf3, sockperf, stress-ng, stream
#   Monitoring tools:   sysstat, procps, lshw, numactl, cpufrequtils
#   Python tools:       python3-pip + matplotlib, numpy (for --charts)
#   ROS 2 (optional):   ros-<distro>-ros-base  + rclpy, std-msgs, tf2, lifecycle
#   Flame graphs:       perf, git clone FlameGraph (brendangregg)
#
# Safe to re-run; apt installs are idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ROS_DISTRO="humble"
SKIP_ROS=false
INSTALL_FLAMEGRAPH=false

for arg in "$@"; do
  case "$arg" in
    --ros-distro=*) ROS_DISTRO="${arg#*=}" ;;
    --skip-ros)     SKIP_ROS=true ;;
    --flamegraph)   INSTALL_FLAMEGRAPH=true ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Must be root (or sudo) to install packages
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root or with sudo" >&2
  exit 2
fi

echo "=== perf-tools dependency installer ==="
echo "ROS distro : ${ROS_DISTRO} (--skip-ros=${SKIP_ROS})"
echo ""

# ─── apt packages ─────────────────────────────────────────────────────────────
echo "[deps] updating apt..."
apt-get update -qq

PKGS=(
  # CPU benchmarks
  sysbench
  # Memory
  mbw
  # Storage
  fio
  # Network
  iperf3
  sockperf
  # CPU stress / thermal
  stress-ng
  # System info / monitoring
  sysstat
  procps
  lshw
  numactl
  cpufrequtils
  # Build tools (needed for stream)
  gcc
  make
  # Python
  python3
  python3-pip
  python3-dev
  # Misc utilities
  jq
  bc
  pciutils
  usbutils
  ethtool
  dmidecode
  lsb-release
  curl
  wget
)

echo "[deps] installing: ${PKGS[*]}"
apt-get install -y --no-install-recommends "${PKGS[@]}"

# ─── Python packages ──────────────────────────────────────────────────────────
echo "[deps] installing Python packages..."
pip3 install --quiet matplotlib numpy

# ─── STREAM memory benchmark (compile from source if not in apt) ──────────────
if ! command -v stream &>/dev/null && ! command -v stream_c &>/dev/null; then
  echo "[deps] STREAM not found in apt; compiling from source..."
  STREAM_DIR="/opt/stream"
  mkdir -p "${STREAM_DIR}"
  STREAM_URL="https://www.cs.virginia.edu/stream/FTP/Code/stream.c"
  curl -fsSL -o "${STREAM_DIR}/stream.c" "${STREAM_URL}" 2>/dev/null \
    || wget -q -O "${STREAM_DIR}/stream.c" "${STREAM_URL}" \
    || { echo "[deps] WARN: could not download STREAM; skipping"; }
  if [[ -f "${STREAM_DIR}/stream.c" ]]; then
    gcc -O3 -march=native -fopenmp \
        -DSTREAM_ARRAY_SIZE=40000000 \
        -o "${STREAM_DIR}/stream_c" "${STREAM_DIR}/stream.c" && \
    ln -sf "${STREAM_DIR}/stream_c" /usr/local/bin/stream_c && \
    echo "[deps] STREAM installed -> /usr/local/bin/stream_c" || \
    echo "[deps] WARN: STREAM compile failed; mbw will be used instead"
  fi
else
  echo "[deps] STREAM already available"
fi

# ─── perf + FlameGraph ────────────────────────────────────────────────────────
if "${INSTALL_FLAMEGRAPH}"; then
  echo "[deps] installing perf..."
  KERNEL="$(uname -r)"
  apt-get install -y --no-install-recommends "linux-tools-${KERNEL}" \
    || apt-get install -y --no-install-recommends linux-tools-generic \
    || echo "[deps] WARN: could not install perf"

  FLAMEGRAPH_DIR="${HOME}/FlameGraph"
  if [[ ! -d "${FLAMEGRAPH_DIR}" ]]; then
    echo "[deps] cloning FlameGraph -> ${FLAMEGRAPH_DIR}"
    git clone --depth=1 https://github.com/brendangregg/FlameGraph.git \
        "${FLAMEGRAPH_DIR}" 2>/dev/null \
      || echo "[deps] WARN: could not clone FlameGraph (internet blocked?)"
  else
    echo "[deps] FlameGraph already at ${FLAMEGRAPH_DIR}"
  fi
fi

# ─── ROS 2 ────────────────────────────────────────────────────────────────────
if ! "${SKIP_ROS}"; then
  echo "[deps] checking ROS 2 ${ROS_DISTRO}..."
  if command -v ros2 &>/dev/null; then
    echo "[deps] ROS 2 already installed: $(ros2 --version 2>/dev/null || echo 'version unknown')"
  else
    UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
    echo "[deps] installing ROS 2 ${ROS_DISTRO} on ${UBUNTU_CODENAME}..."
    # ROS 2 apt key
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
      | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg]" \
      " https://packages.ros.org/ros2/ubuntu ${UBUNTU_CODENAME} main" \
      > /etc/apt/sources.list.d/ros2.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      "ros-${ROS_DISTRO}-ros-base" \
      "ros-${ROS_DISTRO}-rclpy" \
      "ros-${ROS_DISTRO}-std-msgs" \
      "ros-${ROS_DISTRO}-tf2-ros" \
      "ros-${ROS_DISTRO}-lifecycle-msgs" \
      python3-colcon-common-extensions \
      || echo "[deps] WARN: ROS 2 install failed — check internet / ROS apt repo"
  fi

  # Additional ROS 2 Python packages
  pip3 install --quiet rclpy 2>/dev/null || true
else
  echo "[deps] skipping ROS 2 (--skip-ros)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Installation summary ==="
check() {
  local cmd="$1"; local label="${2:-$1}"
  if command -v "${cmd}" &>/dev/null; then
    echo "  ✓ ${label}"
  else
    echo "  ✗ ${label} — NOT FOUND"
  fi
}
check sysbench
check fio
check iperf3
check sockperf
check stream_c "stream_c (STREAM)"
check stress-ng stress-ng
check mbw
check python3
check ros2 "ros2 (ROS 2)"
echo ""
echo "All done. Source ROS 2 environment with:"
echo "  source /opt/ros/${ROS_DISTRO}/setup.bash"
echo ""
echo "Run a quick benchmark suite:"
echo "  ${ROOT}/scripts/run-suite.sh --platform=\$(hostname) --suite=quick"
