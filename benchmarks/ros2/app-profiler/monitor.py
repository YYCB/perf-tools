#!/usr/bin/env python3
"""monitor.py — background per-process resource sampler.

Polls /proc/<pid> files at a fixed interval, writing one newline-delimited
JSON record per sample to <out-dir>/metrics.jsonl.

Sample fields:
  t                   unix timestamp (float)
  pid                 target PID
  cpu_pct             CPU usage relative to one core (multi-threaded process can
                      exceed 100; e.g. 4 fully-loaded threads ≈ 400%)
  rss_mb              resident set size in MB
  vsz_mb              virtual memory size in MB
  threads             live thread count
  vol_ctxt_delta      voluntary context-switches since last sample
  nonvol_ctxt_delta   non-voluntary context-switches since last sample
  io_read_kb          disk bytes read since last sample (KB)
  io_write_kb         disk bytes written since last sample (KB)
  fd_count            open file descriptor count (omitted if not readable)

Exits cleanly when the target process disappears or on SIGTERM / SIGINT.

Usage:
    python3 monitor.py --pid=<pid> --out-dir=<dir> [--interval-ms=500]
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
from pathlib import Path

# CPU clock ticks per second — typically 100 on Linux
_HZ: int = os.sysconf("SC_CLK_TCK")


def _read_stat(pid: int):
    """Return (utime, stime, num_threads) from /proc/<pid>/stat, or None."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            raw = fh.read()
        # The comm field (field 2) is wrapped in () and may contain spaces/parens.
        # Locate the last ')' to find where the remaining fields begin.
        rp = raw.rfind(")")
        if rp < 0:
            return None
        fields = raw[rp + 2:].split()
        # Positions after comm: state(0) ppid(1) … utime(11) stime(12) … num_threads(17)
        return int(fields[11]), int(fields[12]), int(fields[17])
    except (FileNotFoundError, PermissionError, ValueError, IndexError):
        return None


def _read_status(pid: int) -> dict:
    result: dict = {}
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    result["rss_kb"] = int(line.split()[1])
                elif line.startswith("VmSize:"):
                    result["vsz_kb"] = int(line.split()[1])
                elif line.startswith("Threads:"):
                    result["threads"] = int(line.split()[1])
                elif line.startswith("voluntary_ctxt_switches:"):
                    result["vol_ctxt"] = int(line.split()[1])
                elif line.startswith("nonvoluntary_ctxt_switches:"):
                    result["nonvol_ctxt"] = int(line.split()[1])
    except (FileNotFoundError, PermissionError):
        pass
    return result


def _read_io(pid: int) -> dict:
    result: dict = {}
    try:
        with open(f"/proc/{pid}/io") as fh:
            for line in fh:
                if line.startswith("read_bytes:"):
                    result["read_bytes"] = int(line.split()[1])
                elif line.startswith("write_bytes:"):
                    result["write_bytes"] = int(line.split()[1])
    except (FileNotFoundError, PermissionError):
        pass
    return result


def _count_fds(pid: int):
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except (FileNotFoundError, PermissionError):
        return None


def _take_sample(
    pid: int,
    prev_cpu_ticks: int,
    prev_wall: float,
    prev_io: dict,
    prev_ctxt: dict,
) -> tuple:
    """Collect one sample.

    Returns (sample_dict | None, new_prev_cpu_ticks, new_prev_wall,
             new_prev_io, new_prev_ctxt).
    Returns None as the first element when the process has gone away.
    """
    now = time.time()
    stat = _read_stat(pid)
    if stat is None:
        return None, prev_cpu_ticks, prev_wall, prev_io, prev_ctxt

    utime, stime, threads_stat = stat
    proc_ticks = utime + stime
    status = _read_status(pid)
    io = _read_io(pid)
    fd_count = _count_fds(pid)

    delta_ticks = proc_ticks - prev_cpu_ticks
    delta_wall = now - prev_wall
    cpu_pct = (delta_ticks / (delta_wall * _HZ) * 100.0) if delta_wall > 0 else 0.0

    io_read_delta = max(0, io.get("read_bytes", 0) - prev_io.get("read_bytes", 0))
    io_write_delta = max(0, io.get("write_bytes", 0) - prev_io.get("write_bytes", 0))

    vol = status.get("vol_ctxt", 0)
    nonvol = status.get("nonvol_ctxt", 0)

    sample: dict = {
        "t": round(now, 3),
        "pid": pid,
        "cpu_pct": round(cpu_pct, 2),
        "rss_mb": round(status.get("rss_kb", 0) / 1024.0, 2),
        "vsz_mb": round(status.get("vsz_kb", 0) / 1024.0, 2),
        "threads": status.get("threads", threads_stat),
        "vol_ctxt_delta": vol - prev_ctxt.get("vol", 0),
        "nonvol_ctxt_delta": nonvol - prev_ctxt.get("nonvol", 0),
        "io_read_kb": round(io_read_delta / 1024.0, 3),
        "io_write_kb": round(io_write_delta / 1024.0, 3),
    }
    if fd_count is not None:
        sample["fd_count"] = fd_count

    return sample, proc_ticks, now, io, {"vol": vol, "nonvol": nonvol}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--pid", type=int, required=True, help="Target process PID")
    ap.add_argument("--out-dir", required=True, help="Output directory for metrics.jsonl")
    ap.add_argument(
        "--interval-ms",
        type=int,
        default=500,
        help="Sampling interval in milliseconds (default: 500)",
    )
    args = ap.parse_args()

    out_path = Path(args.out_dir) / "metrics.jsonl"
    interval_s = args.interval_ms / 1000.0

    stat0 = _read_stat(args.pid)
    if stat0 is None:
        print(f"monitor: PID {args.pid} not found or not readable", file=sys.stderr)
        return 1

    prev_cpu_ticks = stat0[0] + stat0[1]
    prev_wall = time.time()
    prev_io = _read_io(args.pid)
    s0 = _read_status(args.pid)
    prev_ctxt = {"vol": s0.get("vol_ctxt", 0), "nonvol": s0.get("nonvol_ctxt", 0)}

    running = True

    def _stop(_sig=None, _frame=None) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    print(
        f"monitor: PID={args.pid}  interval={args.interval_ms}ms  -> {out_path}",
        file=sys.stderr,
    )

    with out_path.open("a", encoding="utf-8") as fout:
        while running:
            time.sleep(interval_s)
            samp, prev_cpu_ticks, prev_wall, prev_io, prev_ctxt = _take_sample(
                args.pid, prev_cpu_ticks, prev_wall, prev_io, prev_ctxt
            )
            if samp is None:
                print(f"monitor: PID {args.pid} exited — stopping", file=sys.stderr)
                break
            fout.write(json.dumps(samp) + "\n")
            fout.flush()

    print("monitor: stopped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
