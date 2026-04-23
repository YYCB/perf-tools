#!/usr/bin/env bash
# env-snapshot.sh — collect host environment snapshot into env.json
#
# Usage:
#   ./scripts/env-snapshot.sh --platform=orin [--out-dir=results]
#
# Output:
#   - creates results/<platform>/<run-id>/env.json
#   - prints the run directory path on stdout (so other scripts can capture it)
set -euo pipefail

# ---------- args ----------
PLATFORM=""
OUT_DIR="results"
for arg in "$@"; do
  case "$arg" in
    --platform=*) PLATFORM="${arg#*=}" ;;
    --out-dir=*)  OUT_DIR="${arg#*=}" ;;
    -h|--help)
      sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  echo "ERROR: --platform=<id> is required (e.g. orin / s100 / rk3588 / x86)" >&2
  exit 2
fi

# Run anything that may fail without aborting; return empty string instead.
safe() { "$@" 2>/dev/null || true; }

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
RUN_DIR="${OUT_DIR}/${PLATFORM}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

# Collect everything into environment variables, then hand off to Python
# for safe JSON serialization.
export PT_PLATFORM="${PLATFORM}"
export PT_RUN_ID="${RUN_ID}"
export PT_KERNEL="$(safe uname -a)"
export PT_OS_RELEASE="$(safe cat /etc/os-release)"
export PT_LSCPU="$(safe lscpu)"
export PT_MEMINFO="$(safe head -n 5 /proc/meminfo)"
export PT_GOVERNOR="$(safe cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
export PT_CUR_FREQ_KHZ="$(safe cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)"
export PT_MAX_FREQ_KHZ="$(safe cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"

THERMAL=""
for tz in /sys/class/thermal/thermal_zone*; do
  [[ -r "${tz}/temp" ]] || continue
  type_name="$(safe cat "${tz}/type")"
  temp_milli="$(safe cat "${tz}/temp")"
  THERMAL+="${type_name}=${temp_milli}"$'\n'
done
export PT_THERMAL="${THERMAL}"

# Vendor-specific power tools (best-effort; require sudo on Jetson)
export PT_NVPMODEL="$(safe sudo -n nvpmodel -q)"
export PT_JETSON_CLOCKS="$(safe sudo -n jetson_clocks --show)"

export PT_LSPCI="$(safe lspci)"
export PT_LSUSB="$(safe lsusb)"
export PT_LSBLK="$(safe lsblk -o NAME,SIZE,TYPE,MODEL,ROTA)"

export PT_ROS_DISTRO="${ROS_DISTRO:-}"
export PT_RMW="${RMW_IMPLEMENTATION:-}"
export PT_ROS_DOMAIN="${ROS_DOMAIN_ID:-}"
export PT_CYCLONEDDS_URI="${CYCLONEDDS_URI:-}"
export PT_FASTRTPS_PROFILE="${FASTRTPS_DEFAULT_PROFILES_FILE:-}"

CONTAINER_FLAG="false"
if [[ -f /.dockerenv ]] || grep -qa 'docker\|kubepods\|containerd' /proc/1/cgroup 2>/dev/null; then
  CONTAINER_FLAG="true"
fi
export PT_CONTAINER="${CONTAINER_FLAG}"

export PT_RUNNING_UNITS="$(safe systemctl list-units --state=running --no-legend --no-pager)"
export PT_OUT_PATH="${RUN_DIR}/env.json"

python3 - <<'PY'
import json, os, socket

def env(name):
    return os.environ.get(name, "")

doc = {
    "schema_version": "1",
    "kind": "env-snapshot",
    "platform": env("PT_PLATFORM"),
    "run_id": env("PT_RUN_ID"),
    "host": socket.gethostname(),
    "container": env("PT_CONTAINER") == "true",
    "kernel": env("PT_KERNEL"),
    "os_release": env("PT_OS_RELEASE"),
    "cpu": {
        "lscpu": env("PT_LSCPU"),
        "governor": env("PT_GOVERNOR").strip(),
        "cur_freq_khz": env("PT_CUR_FREQ_KHZ").strip(),
        "max_freq_khz": env("PT_MAX_FREQ_KHZ").strip(),
    },
    "memory": {"meminfo_head": env("PT_MEMINFO")},
    "thermal_milli_c": env("PT_THERMAL"),
    "vendor_power": {
        "nvpmodel": env("PT_NVPMODEL"),
        "jetson_clocks": env("PT_JETSON_CLOCKS"),
    },
    "io": {
        "lsblk": env("PT_LSBLK"),
        "lspci": env("PT_LSPCI"),
        "lsusb": env("PT_LSUSB"),
    },
    "ros2": {
        "ROS_DISTRO": env("PT_ROS_DISTRO"),
        "RMW_IMPLEMENTATION": env("PT_RMW"),
        "ROS_DOMAIN_ID": env("PT_ROS_DOMAIN"),
        "CYCLONEDDS_URI": env("PT_CYCLONEDDS_URI"),
        "FASTRTPS_DEFAULT_PROFILES_FILE": env("PT_FASTRTPS_PROFILE"),
    },
    "running_units": env("PT_RUNNING_UNITS"),
}

out = env("PT_OUT_PATH")
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
print(f"env snapshot -> {out}", file=__import__("sys").stderr)
PY

echo "${RUN_DIR}"
