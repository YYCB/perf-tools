#!/usr/bin/env python3
"""gen-report.py — generate a self-contained HTML performance report.

Reads a profiling session directory produced by profile.sh / monitor.py and
writes a single report.html that contains:
  - Per-state statistics table (avg / p95 / peak CPU%, RSS, threads)
  - Time-series charts drawn with vanilla JS + Canvas (no CDN / external deps)
  - Flame graph SVG embedded inline (if present in the session directory)
  - Environment snapshot summary

Usage:
    python3 gen-report.py \\
        --session-dir=results/orin/my_test_2026-04-24T10-00-00Z \\
        --session-name=my_test \\
        --process=my_ros2_node \\
        --pid=12345 \\
        [--out=report.html]
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# ── Data loading ─────────────────────────────────────────────────────────────

def _load_jsonl(path: Path) -> list[dict]:
    records: list[dict] = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return records


# ── Statistics ───────────────────────────────────────────────────────────────

def _pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def _stat(vals: list[float]) -> dict[str, Any]:
    if not vals:
        return {"avg": None, "p50": None, "p95": None, "max": None, "min": None, "count": 0}
    return {
        "avg":   round(statistics.fmean(vals), 2),
        "p50":   round(_pct(vals, 50), 2),
        "p95":   round(_pct(vals, 95), 2),
        "max":   round(max(vals), 2),
        "min":   round(min(vals), 2),
        "count": len(vals),
    }


def _fmt(v: float | None, decimals: int = 1) -> str:
    return "—" if v is None else f"{v:.{decimals}f}"


# ── Per-state statistics ──────────────────────────────────────────────────────

def compute_state_stats(
    samples: list[dict],
    states: list[dict],
    t0: float,
) -> list[dict[str, Any]]:
    """Compute statistics for each state interval.

    Each state covers [ states[i].t , states[i+1].t ).
    """
    if not states:
        states = [{"t": t0, "label": "all", "t_rel": 0.0}]

    result: list[dict[str, Any]] = []
    for i, st in enumerate(states):
        t_start = st["t"]
        t_end = states[i + 1]["t"] if i + 1 < len(states) else float("inf")
        duration = (t_end - t_start) if t_end != float("inf") else None

        seg = [s for s in samples if t_start <= s["t"] < t_end]
        cpu = [s["cpu_pct"] for s in seg if "cpu_pct" in s]
        rss = [s["rss_mb"]  for s in seg if "rss_mb"  in s]
        thr = [float(s["threads"]) for s in seg if "threads" in s]
        vol = [float(s["vol_ctxt_delta"]) for s in seg if "vol_ctxt_delta" in s]
        fds = [float(s["fd_count"]) for s in seg if "fd_count" in s]

        result.append({
            "label":       st["label"],
            "t_start":     t_start,
            "t_end":       t_end,
            "t_rel":       round(st.get("t_rel", t_start - t0), 3),
            "t_end_rel":   round(t_end - t0, 3) if t_end != float("inf") else None,
            "duration_s":  round(duration, 1) if duration is not None else None,
            "sample_count": len(seg),
            "cpu":  _stat(cpu),
            "rss":  _stat(rss),
            "threads": _stat(thr),
            "vol_ctxt": _stat(vol),
            "fds":  _stat(fds),
        })
    return result


def _state_table_rows(state_stats: list[dict]) -> str:
    rows: list[str] = []
    for ss in state_stats:
        lbl = ss["label"]
        if lbl in ("session_start", "session_end"):
            continue
        dur = f"{ss['duration_s']:.1f} s" if ss["duration_s"] is not None else "ongoing"
        rows.append(
            f"<tr>"
            f"<td><code>{lbl}</code></td>"
            f"<td>{dur}</td>"
            f"<td>{_fmt(ss['cpu']['avg'])}%</td>"
            f"<td>{_fmt(ss['cpu']['p95'])}%</td>"
            f"<td>{_fmt(ss['cpu']['max'])}%</td>"
            f"<td>{_fmt(ss['rss']['avg'])} MB</td>"
            f"<td>{_fmt(ss['rss']['max'])} MB</td>"
            f"<td>{_fmt(ss['threads']['avg'], 0)}</td>"
            f"<td>{ss['sample_count']}</td>"
            f"</tr>"
        )
    return "\n".join(rows) if rows else "<tr><td colspan='9' class='empty'>No named states — use <code>m &lt;label&gt;</code> in the REPL to mark states</td></tr>"


# ── Environment summary ───────────────────────────────────────────────────────

def _env_items(env_path: Path) -> list[tuple[str, str]]:
    if not env_path.exists():
        return []
    try:
        env = json.loads(env_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    cpu = env.get("cpu", {})
    ros = env.get("ros2", {})
    items = [
        ("Platform",         env.get("platform", "—")),
        ("Host",             env.get("host", "—")),
        ("Kernel",           (env.get("kernel") or "").splitlines()[0] if env.get("kernel") else "—"),
        ("Container",        str(env.get("container", False))),
        ("CPU governor",     cpu.get("governor") or "—"),
        ("CPU max freq",     (cpu.get("max_freq_khz") or "—") + (" kHz" if cpu.get("max_freq_khz") else "")),
        ("ROS_DISTRO",       ros.get("ROS_DISTRO") or "—"),
        ("RMW_IMPLEMENTATION", ros.get("RMW_IMPLEMENTATION") or "—"),
        ("ROS_DOMAIN_ID",    ros.get("ROS_DOMAIN_ID") or "—"),
    ]
    thermal = env.get("thermal_milli_c", "")
    if thermal:
        first_zone = thermal.strip().splitlines()[0] if thermal.strip() else ""
        if first_zone:
            name, _, milli = first_zone.partition("=")
            try:
                items.append(("Temp (first zone)", f"{name} = {int(milli)/1000:.1f} °C"))
            except ValueError:
                pass
    return items


# ── Inline JS chart renderer (vanilla Canvas, no CDN) ────────────────────────

_CHART_JS = r"""
(function () {
  var PALETTE = ['#4e79a7','#f28e2b','#59a14f','#e15759','#76b7b2','#af7aa1','#ff9da7','#9c755f'];

  function drawChart(canvasId, opts) {
    var canvas = document.getElementById(canvasId);
    if (!canvas) return;
    canvas.width  = (canvas.parentElement.offsetWidth || 880) - 2;
    canvas.height = 230;
    var ctx = canvas.getContext('2d');
    var W = canvas.width, H = canvas.height;
    var pad = {t: 28, r: 16, b: 42, l: 64};
    var pw = W - pad.l - pad.r, ph = H - pad.t - pad.b;
    var key = opts.key, samples = opts.samples, states = opts.states, t0 = opts.t0;

    /* --- build value + time arrays (skip nulls) --- */
    var vals = [], allTimes = [];
    for (var i = 0; i < samples.length; i++) {
      var v = samples[i][key];
      if (v != null) { vals.push(v); allTimes.push(samples[i].t - t0); }
    }
    if (vals.length === 0) {
      ctx.fillStyle = '#aaa'; ctx.font = '13px sans-serif';
      ctx.textAlign = 'center'; ctx.fillText('No data', W / 2, H / 2);
      return;
    }

    var maxT = allTimes[allTimes.length - 1] || 1;
    var rawMax = Math.max.apply(null, vals);
    var rawMin = Math.min.apply(null, vals);
    if (rawMax === rawMin) rawMax = rawMin + 1;
    var maxV = rawMax * 1.08;
    var minV = rawMin > 0 ? 0 : rawMin;

    var tx = function (t) { return pad.l + (t / maxT) * pw; };
    var ty = function (v) { return pad.t + ph - ((v - minV) / (maxV - minV)) * ph; };

    /* --- state background bands --- */
    for (var si = 0; si < states.length; si++) {
      var s = states[si];
      if (s.label === 'session_start' || s.label === 'session_end') continue;
      var x1 = tx(s.t_rel);
      var x2 = tx(s.t_end_rel != null ? s.t_end_rel : maxT);
      ctx.fillStyle = PALETTE[si % PALETTE.length] + '18';
      ctx.fillRect(x1, pad.t, x2 - x1, ph);
      ctx.save();
      ctx.strokeStyle = PALETTE[si % PALETTE.length] + '99';
      ctx.lineWidth = 1; ctx.setLineDash([4, 3]);
      ctx.beginPath(); ctx.moveTo(x1, pad.t); ctx.lineTo(x1, pad.t + ph); ctx.stroke();
      ctx.restore();
      ctx.fillStyle = PALETTE[si % PALETTE.length];
      ctx.font = '9px monospace'; ctx.textAlign = 'left';
      ctx.fillText(s.label, x1 + 3, pad.t + 11);
    }

    /* --- horizontal grid --- */
    var nY = 4;
    for (var gi = 0; gi <= nY; gi++) {
      var gv = minV + (maxV - minV) * (gi / nY);
      var gy = ty(gv);
      ctx.strokeStyle = '#e5e5e5'; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(pad.l, gy); ctx.lineTo(pad.l + pw, gy); ctx.stroke();
      ctx.fillStyle = '#777'; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
      ctx.fillText(gv < 1 ? gv.toFixed(2) : gv.toFixed(1), pad.l - 5, gy + 4);
    }

    /* --- vertical grid + time labels --- */
    var nX = Math.min(8, Math.max(2, Math.floor(maxT / 10) || 1));
    ctx.textAlign = 'center';
    for (var xi = 0; xi <= nX; xi++) {
      var xt = maxT * (xi / nX);
      var xx = tx(xt);
      ctx.strokeStyle = '#e5e5e5'; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(xx, pad.t); ctx.lineTo(xx, pad.t + ph); ctx.stroke();
      ctx.fillStyle = '#777'; ctx.font = '10px sans-serif';
      ctx.fillText(xt.toFixed(0) + 's', xx, pad.t + ph + 14);
    }

    /* --- data line --- */
    ctx.strokeStyle = PALETTE[0]; ctx.lineWidth = 1.8;
    ctx.lineJoin = 'round'; ctx.beginPath();
    var first = true;
    for (var li = 0; li < samples.length; li++) {
      var lv = samples[li][key];
      if (lv == null) { first = true; continue; }
      var lt = samples[li].t - t0;
      var lx = tx(lt), ly = ty(lv);
      if (first) { ctx.moveTo(lx, ly); first = false; } else { ctx.lineTo(lx, ly); }
    }
    ctx.stroke();

    /* --- axes --- */
    ctx.strokeStyle = '#bbb'; ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(pad.l, pad.t); ctx.lineTo(pad.l, pad.t + ph);
    ctx.lineTo(pad.l + pw, pad.t + ph);
    ctx.stroke();

    /* --- title & unit --- */
    ctx.fillStyle = '#333'; ctx.font = 'bold 11px sans-serif'; ctx.textAlign = 'left';
    ctx.fillText(opts.title, pad.l, pad.t - 8);
    ctx.fillStyle = '#999'; ctx.font = '10px sans-serif';
    ctx.fillText(opts.unit, pad.l + ctx.measureText(opts.title + '  ').width, pad.t - 8);
  }

  var CHARTS = [
    {id: 'cpu-chart',  key: 'cpu_pct',          title: 'CPU Usage',                   unit: '% (per core)'},
    {id: 'rss-chart',  key: 'rss_mb',            title: 'Resident Memory (RSS)',        unit: 'MB'},
    {id: 'thr-chart',  key: 'threads',           title: 'Thread Count',                unit: 'count'},
    {id: 'ctx-chart',  key: 'vol_ctxt_delta',    title: 'Voluntary Context Switches',   unit: '\u0394 / sample'},
    {id: 'fd-chart',   key: 'fd_count',          title: 'Open File Descriptors',        unit: 'count'},
    {id: 'ior-chart',  key: 'io_read_kb',        title: 'Disk Read Rate',              unit: 'KB / sample'},
    {id: 'iow-chart',  key: 'io_write_kb',       title: 'Disk Write Rate',             unit: 'KB / sample'},
  ];

  window.addEventListener('DOMContentLoaded', function () {
    var d = window.__PERF_DATA__;
    if (!d) return;
    CHARTS.forEach(function (c) {
      drawChart(c.id, {key: c.key, title: c.title, unit: c.unit,
                       samples: d.samples, states: d.states, t0: d.t0});
    });
  });
}());
"""

_CSS = """
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, -apple-system, sans-serif; font-size: 14px;
       background: #f0f2f5; color: #1e293b; line-height: 1.5; }
a { color: #3b82f6; }
header { background: #0f172a; color: #e2e8f0; padding: 20px 32px; }
header h1 { font-size: 20px; font-weight: 700; margin-bottom: 6px; }
header .meta { font-size: 12px; opacity: .7; display: flex; gap: 24px; flex-wrap: wrap; }
header .meta b { color: #94a3b8; font-weight: 500; }
.container { max-width: 1280px; margin: 24px auto; padding: 0 20px; }
section { background: #fff; border-radius: 8px;
          box-shadow: 0 1px 3px rgba(0,0,0,.08); margin-bottom: 20px;
          padding: 20px 24px; }
h2 { font-size: 15px; font-weight: 600; color: #0f172a; margin-bottom: 14px;
     padding-bottom: 8px; border-bottom: 1px solid #e2e8f0; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { background: #f8fafc; font-weight: 600; color: #475569;
     text-align: left; padding: 8px 10px; border-bottom: 2px solid #e2e8f0; }
td { padding: 7px 10px; border-bottom: 1px solid #f1f5f9; color: #334155; }
tr:last-child td { border-bottom: none; }
tr:hover td { background: #f8fafc; }
td.empty { color: #94a3b8; font-style: italic; }
code { font-family: ui-monospace, monospace; font-size: 12px;
       background: #f1f5f9; padding: 1px 5px; border-radius: 3px; }
.chart-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.chart-box { background: #fafafa; border: 1px solid #e5e7eb;
             border-radius: 6px; padding: 10px 12px; }
canvas { display: block; width: 100%; }
.flame-wrap { overflow: auto; border: 1px solid #e5e7eb;
              border-radius: 6px; padding: 8px; background: #fafafa; }
.flame-wrap svg { max-width: 100%; display: block; }
.env-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 4px; }
.env-row { display: flex; gap: 12px; padding: 5px 0;
           border-bottom: 1px solid #f3f4f6; align-items: baseline; }
.env-key { color: #64748b; font-size: 12px; min-width: 160px; flex-shrink: 0; }
.env-val { color: #1e293b; font-size: 12px; font-weight: 500;
           word-break: break-all; font-family: ui-monospace, monospace; }
footer { text-align: center; font-size: 11px; color: #94a3b8; padding: 24px; }
@media (max-width: 800px) { .chart-grid { grid-template-columns: 1fr; } }
"""


# ── HTML assembly ─────────────────────────────────────────────────────────────

def _build_html(
    session_name: str,
    process: str,
    pid: str,
    session_dir: Path,
    samples: list[dict],
    states: list[dict],
    state_stats: list[dict],
    env_rows: list[tuple[str, str]],
    flamegraph_path: Path | None,
) -> str:
    t0 = samples[0]["t"] if samples else 0.0
    total_s = round(samples[-1]["t"] - t0, 1) if len(samples) > 1 else 0.0
    gen_time = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    n_states = sum(1 for ss in state_stats if ss["label"] not in ("session_start", "session_end"))

    # ── State comparison table ──
    state_rows_html = _state_table_rows(state_stats)

    # ── Environment section ──
    env_section = ""
    if env_rows:
        items_html = "".join(
            f'<div class="env-row">'
            f'<span class="env-key">{k}</span>'
            f'<span class="env-val">{v}</span>'
            f'</div>'
            for k, v in env_rows
        )
        env_section = (
            f'<section><h2>Environment Snapshot</h2>'
            f'<div class="env-grid">{items_html}</div></section>'
        )

    # ── Flame graph section ──
    flame_section = ""
    if flamegraph_path and flamegraph_path.exists():
        svg = flamegraph_path.read_text(encoding="utf-8")
        flame_section = (
            f'<section><h2>Flame Graph</h2>'
            f'<div class="flame-wrap">{svg}</div></section>'
        )

    # ── JS data payload ──
    # Build states list with t_end_rel populated
    js_states: list[dict] = []
    for i, s in enumerate(states):
        t_rel = s.get("t_rel", s["t"] - t0)
        t_end_rel = (
            states[i + 1].get("t_rel", states[i + 1]["t"] - t0)
            if i + 1 < len(states) else None
        )
        js_states.append({
            "label":    s["label"],
            "t_rel":    round(t_rel, 3),
            "t_end_rel": round(t_end_rel, 3) if t_end_rel is not None else None,
        })

    js_payload = json.dumps(
        {"t0": t0, "samples": samples, "states": js_states},
        separators=(",", ":"),
    )

    chart_ids = ["cpu-chart", "rss-chart", "thr-chart", "ctx-chart",
                 "fd-chart", "ior-chart", "iow-chart"]
    charts_html = "".join(
        f'<div class="chart-box"><canvas id="{cid}"></canvas></div>'
        for cid in chart_ids
    )

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Perf Report: {session_name}</title>
<style>{_CSS}</style>
</head>
<body>
<header>
  <h1>&#x1F525; ROS 2 App Profiler Report</h1>
  <div class="meta">
    <span><b>Session</b> {session_name}</span>
    <span><b>Process</b> {process} (PID {pid})</span>
    <span><b>Duration</b> {total_s} s</span>
    <span><b>Samples</b> {len(samples)}</span>
    <span><b>States</b> {n_states}</span>
    <span><b>Generated</b> {gen_time}</span>
  </div>
</header>

<div class="container">

<section>
  <h2>State Comparison</h2>
  <table>
    <thead>
      <tr>
        <th>State label</th><th>Duration</th>
        <th>Avg CPU%</th><th>p95 CPU%</th><th>Peak CPU%</th>
        <th>Avg RSS</th><th>Peak RSS</th>
        <th>Avg Threads</th><th>Samples</th>
      </tr>
    </thead>
    <tbody>
{state_rows_html}
    </tbody>
  </table>
</section>

<section>
  <h2>Time-series Charts</h2>
  <p style="font-size:12px;color:#64748b;margin-bottom:12px;">
    Coloured bands = named states &nbsp;|&nbsp;
    CPU% is per-core (multi-threaded: can exceed 100%)
  </p>
  <div class="chart-grid">
{charts_html}
  </div>
</section>

{flame_section}

{env_section}

</div>

<footer>Generated by perf-tools/benchmarks/ros2/app-profiler &mdash; {gen_time}</footer>

<script>
window.__PERF_DATA__ = {js_payload};
{_CHART_JS}
</script>
</body>
</html>"""


# ── CLI entry point ───────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--session-dir", required=True, help="Session directory path")
    ap.add_argument("--session-name", default="", help="Human-readable session name")
    ap.add_argument("--process", default="", help="Target process name (comm)")
    ap.add_argument("--pid", default="", help="Target PID")
    ap.add_argument("--out", default="", help="Output HTML path (default: <session-dir>/report.html)")
    args = ap.parse_args()

    session_dir = Path(args.session_dir)
    if not session_dir.is_dir():
        print(f"gen-report: session dir not found: {session_dir}", file=sys.stderr)
        return 1

    metrics_path = session_dir / "metrics.jsonl"
    states_path  = session_dir / "states.jsonl"
    env_path     = session_dir / "env.json"
    out_path     = Path(args.out) if args.out else session_dir / "report.html"

    samples = _load_jsonl(metrics_path)
    states  = _load_jsonl(states_path)

    if not samples:
        print("gen-report: metrics.jsonl is empty — nothing to report", file=sys.stderr)
        return 1

    t0 = samples[0]["t"]

    # Ensure t_rel is set on every state marker
    for s in states:
        if "t_rel" not in s:
            s["t_rel"] = round(s["t"] - t0, 3)

    state_stats  = compute_state_stats(samples, states, t0)
    env_rows     = _env_items(env_path)

    # Find first flame graph SVG in the session directory
    svg_candidates = sorted(session_dir.glob("flamegraph*.svg"))
    flamegraph_path = svg_candidates[0] if svg_candidates else None

    html = _build_html(
        session_name=args.session_name or session_dir.name,
        process=args.process,
        pid=args.pid,
        session_dir=session_dir,
        samples=samples,
        states=states,
        state_stats=state_stats,
        env_rows=env_rows,
        flamegraph_path=flamegraph_path,
    )

    out_path.write_text(html, encoding="utf-8")
    print(f"gen-report: report written -> {out_path}", file=sys.stderr)
    print(str(out_path))   # stdout for callers to capture
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
