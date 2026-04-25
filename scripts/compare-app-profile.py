#!/usr/bin/env python3
"""compare-app-profile.py — diff two app-profiler session directories.

Inputs are two session directories produced by
``benchmarks/ros2/app-profiler/profile.sh``.  Each session directory is
expected to contain (some of) the following files:

    metrics.jsonl              time-series samples (one per line)
    states.jsonl               user-marked state boundaries
    env.json                   environment snapshot
    ros2.app-profiler.json     schema-v1 summary (optional)

The tool produces a single self-contained ``compare.html`` that contains:

  * a header with both session labels
  * a fairness statement comparing the two ``env.json`` snapshots
  * a global summary table (avg/p50/p95/p99/max for CPU, RSS, threads, FDs)
    with Δ%% and a lower-is-better aware verdict
  * a per-state table (only labels common to both sessions)
  * time-series overlay charts (vanilla JS + Canvas, no CDN) with both
    sessions plotted on the same axes; state bands use the union of
    state labels.

Usage::

    python3 scripts/compare-app-profile.py \\
        --a results/orin/baseline_2026-04-24T10-00-00Z \\
        --b results/orin/feature-on_2026-04-24T11-00-00Z \\
        [--label-a=baseline] [--label-b=feature-on] \\
        [--out=reports/baseline-vs-feature-on.html]

The HTML is fully offline and can be opened in any browser.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Constants ────────────────────────────────────────────────────────────────

# Metric-name substrings that imply lower values are better.  Mirrors
# scripts/compare.py so the two tools agree on verdicts.
LOWER_BETTER_HINTS = (
    "latency", "jitter", "delay", "wakeup", "temp", "power_w",
    "error", "loss", "miss", "rss", "vsz", "cpu", "ctxt", "fd",
    "io_read", "io_write", "threads",
)


def is_lower_better(metric_name: str) -> bool:
    name = metric_name.lower()
    return any(h in name for h in LOWER_BETTER_HINTS)


# ── Data loading ─────────────────────────────────────────────────────────────

def _load_jsonl(path: Path) -> list[dict]:
    records: list[dict] = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # Skip malformed lines silently — same policy as gen-report.
                pass
    return records


def _load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def load_session(session_dir: Path) -> dict[str, Any]:
    if not session_dir.is_dir():
        sys.exit(f"compare-app-profile: not a directory: {session_dir}")
    samples = _load_jsonl(session_dir / "metrics.jsonl")
    states = _load_jsonl(session_dir / "states.jsonl")
    env = _load_json(session_dir / "env.json")
    summary = _load_json(session_dir / "ros2.app-profiler.json")
    if not samples:
        sys.exit(
            f"compare-app-profile: {session_dir}/metrics.jsonl is empty or "
            "missing — nothing to compare"
        )
    t0 = samples[0]["t"]
    # Ensure t_rel is set on every state marker (gen-report does the same).
    for s in states:
        if "t_rel" not in s:
            s["t_rel"] = round(s["t"] - t0, 3)
    return {
        "path": session_dir,
        "samples": samples,
        "states": states,
        "env": env,
        "summary": summary,
        "t0": t0,
    }


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
        return {"avg": None, "p50": None, "p95": None, "p99": None,
                "max": None, "min": None, "count": 0}
    return {
        "avg":   round(statistics.fmean(vals), 2),
        "p50":   round(_pct(vals, 50), 2),
        "p95":   round(_pct(vals, 95), 2),
        "p99":   round(_pct(vals, 99), 2),
        "max":   round(max(vals), 2),
        "min":   round(min(vals), 2),
        "count": len(vals),
    }


# Metric key → (display name, unit, /proc field key in metrics.jsonl).
# Order matters: it dictates table & chart row order.
METRIC_DEFS: list[tuple[str, str, str, str]] = [
    ("cpu_pct",        "CPU %",            "% (per core)", "cpu_pct"),
    ("rss_mb",         "RSS",              "MB",           "rss_mb"),
    ("threads",        "Threads",          "count",        "threads"),
    ("fd_count",       "Open FDs",         "count",        "fd_count"),
    ("vol_ctxt_delta", "Vol ctx-switches", "Δ / sample",   "vol_ctxt_delta"),
]


def collect_metric_series(samples: list[dict], key: str) -> list[float]:
    out: list[float] = []
    for s in samples:
        v = s.get(key)
        if isinstance(v, (int, float)):
            out.append(float(v))
    return out


def compute_global_stats(session: dict[str, Any]) -> dict[str, dict]:
    return {
        key: _stat(collect_metric_series(session["samples"], key))
        for key, _, _, _ in METRIC_DEFS
    }


# ── Per-state slicing (keyed by label) ───────────────────────────────────────

def _state_intervals(states: list[dict], samples: list[dict]) -> dict[str, tuple[float, float]]:
    """Return {label: (t_start, t_end)} for each named state.

    Only labels that are not ``session_start`` / ``session_end`` are returned.
    Each interval covers ``[states[i].t, states[i+1].t)`` — same convention
    used by gen-report.py.  If a label appears multiple times, the first
    occurrence wins (callers should mark each label once per session).
    """
    if not samples:
        return {}
    last_t = samples[-1]["t"]
    out: dict[str, tuple[float, float]] = {}
    for i, st in enumerate(states):
        label = st.get("label", "")
        if label in ("", "session_start", "session_end"):
            continue
        if label in out:
            continue
        t_start = st["t"]
        t_end = states[i + 1]["t"] if i + 1 < len(states) else last_t
        out[label] = (t_start, t_end)
    return out


def per_state_stats(session: dict[str, Any]) -> dict[str, dict[str, dict]]:
    """{label: {metric_key: stat-dict}} for every named state."""
    intervals = _state_intervals(session["states"], session["samples"])
    samples = session["samples"]
    result: dict[str, dict[str, dict]] = {}
    for label, (t0, t1) in intervals.items():
        seg = [s for s in samples if t0 <= s["t"] < t1]
        result[label] = {
            key: _stat([float(s[key]) for s in seg if isinstance(s.get(key), (int, float))])
            for key, _, _, _ in METRIC_DEFS
        }
    return result


# ── Verdicts & formatting ────────────────────────────────────────────────────

def _fmt(v: float | None, decimals: int = 2) -> str:
    if v is None:
        return "—"
    if abs(v) >= 1000:
        return f"{v:,.1f}"
    return f"{v:.{decimals}f}"


def _delta_pct(av: float | None, bv: float | None) -> str:
    if av is None or bv is None:
        return "—"
    if av == 0:
        return "+∞%" if bv > 0 else ("-∞%" if bv < 0 else "0%")
    return f"{(bv - av) / av * 100.0:+.1f}%"


def _verdict(av: float | None, bv: float | None, metric_key: str) -> str:
    if av is None or bv is None:
        return "—"
    if av == bv:
        return "="
    lower_better = is_lower_better(metric_key)
    if (bv < av) == lower_better:
        return "B better"
    return "A better"


# ── Fairness statement ───────────────────────────────────────────────────────

def _first_line(s: str | None) -> str | None:
    if not s:
        return None
    lines = s.splitlines()
    return lines[0] if lines else None


def fairness_rows(env_a: dict, env_b: dict) -> list[tuple[str, Any, Any]]:
    cpu_a = env_a.get("cpu", {}) or {}
    cpu_b = env_b.get("cpu", {}) or {}
    ros_a = env_a.get("ros2", {}) or {}
    ros_b = env_b.get("ros2", {}) or {}
    return [
        ("Platform",         env_a.get("platform"),       env_b.get("platform")),
        ("Host",             env_a.get("host"),           env_b.get("host")),
        ("Container",        env_a.get("container"),      env_b.get("container")),
        ("Kernel",           _first_line(env_a.get("kernel")), _first_line(env_b.get("kernel"))),
        ("CPU governor",     cpu_a.get("governor"),       cpu_b.get("governor")),
        ("CPU max freq (kHz)", cpu_a.get("max_freq_khz"), cpu_b.get("max_freq_khz")),
        ("ROS_DISTRO",       ros_a.get("ROS_DISTRO"),     ros_b.get("ROS_DISTRO")),
        ("RMW_IMPLEMENTATION", ros_a.get("RMW_IMPLEMENTATION"), ros_b.get("RMW_IMPLEMENTATION")),
        ("ROS_DOMAIN_ID",    ros_a.get("ROS_DOMAIN_ID"),  ros_b.get("ROS_DOMAIN_ID")),
    ]


# ── HTML rendering ───────────────────────────────────────────────────────────

_CSS = """
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, -apple-system, sans-serif; font-size: 14px;
       background: #f0f2f5; color: #1e293b; line-height: 1.5; }
header { background: #0f172a; color: #e2e8f0; padding: 20px 32px; }
header h1 { font-size: 20px; font-weight: 700; margin-bottom: 6px; }
header .meta { font-size: 12px; opacity: .8; display: flex; gap: 24px; flex-wrap: wrap; }
header .meta b { color: #94a3b8; font-weight: 500; }
header .legend { display: inline-flex; align-items: center; gap: 6px; }
header .legend .swatch { width: 12px; height: 12px; border-radius: 2px; display: inline-block; }
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
td.empty, td.dim { color: #94a3b8; font-style: italic; }
td.warn { color: #b45309; }
td.a-better { color: #047857; font-weight: 600; }
td.b-better { color: #b91c1c; font-weight: 600; }
code { font-family: ui-monospace, monospace; font-size: 12px;
       background: #f1f5f9; padding: 1px 5px; border-radius: 3px; }
.chart-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.chart-box { background: #fafafa; border: 1px solid #e5e7eb;
             border-radius: 6px; padding: 10px 12px; }
canvas { display: block; width: 100%; }
footer { text-align: center; font-size: 11px; color: #94a3b8; padding: 24px; }
.note { font-size: 12px; color: #64748b; margin-bottom: 12px; }
@media (max-width: 800px) { .chart-grid { grid-template-columns: 1fr; } }
"""

# Two-series Canvas chart.  Series A uses the "A" palette colour, series B
# the "B" colour.  Time is each session's local elapsed seconds since its
# own t0 — overlaying on a common elapsed-time axis is the most useful
# alignment for "feature on vs off"-style A/B runs.
_CHART_JS = r"""
(function () {
  var COL_A = '#4e79a7';
  var COL_B = '#e15759';
  var STATE_PAL_A = '#4e79a780';
  var STATE_PAL_B = '#e1575980';

  function maxRel(samples) {
    var t0 = samples[0].t;
    return samples[samples.length - 1].t - t0;
  }

  function drawChart(canvasId, opts) {
    var canvas = document.getElementById(canvasId);
    if (!canvas) return;
    canvas.width  = (canvas.parentElement.offsetWidth || 880) - 2;
    canvas.height = 240;
    var ctx = canvas.getContext('2d');
    var W = canvas.width, H = canvas.height;
    var pad = {t: 28, r: 16, b: 42, l: 64};
    var pw = W - pad.l - pad.r, ph = H - pad.t - pad.b;

    var key = opts.key;
    var sA = opts.a.samples, sB = opts.b.samples;
    var t0A = opts.a.t0, t0B = opts.b.t0;

    var allVals = [];
    for (var i = 0; i < sA.length; i++) { var v = sA[i][key]; if (v != null) allVals.push(v); }
    for (var i = 0; i < sB.length; i++) { var v = sB[i][key]; if (v != null) allVals.push(v); }

    if (allVals.length === 0) {
      ctx.fillStyle = '#aaa'; ctx.font = '13px sans-serif';
      ctx.textAlign = 'center'; ctx.fillText('No data', W / 2, H / 2);
      return;
    }

    var maxT_A = sA.length > 1 ? (sA[sA.length - 1].t - t0A) : 0;
    var maxT_B = sB.length > 1 ? (sB[sB.length - 1].t - t0B) : 0;
    var maxT = Math.max(maxT_A, maxT_B, 1);
    var rawMax = Math.max.apply(null, allVals);
    var rawMin = Math.min.apply(null, allVals);
    if (rawMax === rawMin) rawMax = rawMin + 1;
    var maxV = rawMax * 1.08;
    var minV = rawMin > 0 ? 0 : rawMin;

    var tx = function (t) { return pad.l + (t / maxT) * pw; };
    var ty = function (v) { return pad.t + ph - ((v - minV) / (maxV - minV)) * ph; };

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

    /* --- vertical grid + time labels (elapsed seconds) --- */
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

    /* --- draw a series --- */
    function drawSeries(samples, t0, colour) {
      ctx.strokeStyle = colour; ctx.lineWidth = 1.6;
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
    }
    drawSeries(sA, t0A, COL_A);
    drawSeries(sB, t0B, COL_B);

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

    /* --- inline legend (top-right) --- */
    var lx = pad.l + pw - 110, ly = pad.t - 10;
    ctx.fillStyle = COL_A; ctx.fillRect(lx, ly, 10, 3);
    ctx.fillStyle = '#333'; ctx.font = '10px sans-serif';
    ctx.fillText(opts.labelA || 'A', lx + 14, ly + 4);
    ctx.fillStyle = COL_B; ctx.fillRect(lx + 60, ly, 10, 3);
    ctx.fillStyle = '#333';
    ctx.fillText(opts.labelB || 'B', lx + 74, ly + 4);
  }

  window.addEventListener('DOMContentLoaded', function () {
    var d = window.__CMP_DATA__;
    if (!d) return;
    d.charts.forEach(function (c) {
      drawChart(c.id, {
        key: c.key, title: c.title, unit: c.unit,
        a: d.a, b: d.b, labelA: d.labelA, labelB: d.labelB,
      });
    });
  });
}());
"""


def _summary_table_html(
    a_stats: dict[str, dict],
    b_stats: dict[str, dict],
    label_a: str,
    label_b: str,
) -> str:
    rows: list[str] = []
    # Stat table (Avg / p50 / p95 / p99 / Max) per metric.
    for key, display, unit, _ in METRIC_DEFS:
        a = a_stats.get(key, {})
        b = b_stats.get(key, {})
        for stat_key, stat_label in (
            ("avg", "avg"), ("p50", "p50"), ("p95", "p95"),
            ("p99", "p99"), ("max", "max"),
        ):
            av = a.get(stat_key)
            bv = b.get(stat_key)
            verdict = _verdict(av, bv, key)
            verdict_cls = ""
            if verdict == "A better":
                verdict_cls = "a-better"
            elif verdict == "B better":
                verdict_cls = "b-better"
            rows.append(
                "<tr>"
                f"<td><code>{display}</code></td><td>{unit}</td>"
                f"<td>{stat_label}</td>"
                f"<td>{_fmt(av)}</td><td>{_fmt(bv)}</td>"
                f"<td>{_delta_pct(av, bv)}</td>"
                f'<td class="{verdict_cls}">{verdict}</td>'
                "</tr>"
            )
    return "\n".join(rows)


def _per_state_table_html(
    a_states: dict[str, dict[str, dict]],
    b_states: dict[str, dict[str, dict]],
) -> str:
    common = sorted(set(a_states) & set(b_states))
    only_a = sorted(set(a_states) - set(b_states))
    only_b = sorted(set(b_states) - set(a_states))

    if not common and not only_a and not only_b:
        return (
            "<tr><td colspan='8' class='empty'>"
            "No named states in either session — use <code>m &lt;label&gt;</code> "
            "in the REPL to mark states"
            "</td></tr>"
        )

    rows: list[str] = []
    for label in common:
        for key, display, unit, _ in METRIC_DEFS:
            a = a_states[label].get(key, {})
            b = b_states[label].get(key, {})
            for stat_key in ("avg", "p95", "p99", "max"):
                av = a.get(stat_key)
                bv = b.get(stat_key)
                verdict = _verdict(av, bv, key)
                verdict_cls = ""
                if verdict == "A better":
                    verdict_cls = "a-better"
                elif verdict == "B better":
                    verdict_cls = "b-better"
                rows.append(
                    "<tr>"
                    f"<td><code>{label}</code></td>"
                    f"<td><code>{display}</code></td><td>{unit}</td>"
                    f"<td>{stat_key}</td>"
                    f"<td>{_fmt(av)}</td><td>{_fmt(bv)}</td>"
                    f"<td>{_delta_pct(av, bv)}</td>"
                    f'<td class="{verdict_cls}">{verdict}</td>'
                    "</tr>"
                )
    for label in only_a:
        rows.append(
            f"<tr><td><code>{label}</code></td>"
            f'<td colspan="7" class="warn">only present in A</td></tr>'
        )
    for label in only_b:
        rows.append(
            f"<tr><td><code>{label}</code></td>"
            f'<td colspan="7" class="warn">only present in B</td></tr>'
        )
    return "\n".join(rows)


def _fairness_table_html(env_a: dict, env_b: dict, label_a: str, label_b: str) -> str:
    rows: list[str] = []
    for name, a, b in fairness_rows(env_a, env_b):
        a_s = "—" if a in (None, "") else str(a)
        b_s = "—" if b in (None, "") else str(b)
        marker = ""
        cls = ""
        if a_s != b_s:
            marker = " ⚠️"
            cls = "warn"
        rows.append(
            f"<tr><td>{name}{marker}</td>"
            f'<td class="{cls}">{a_s}</td>'
            f'<td class="{cls}">{b_s}</td></tr>'
        )
    return "\n".join(rows)


def _build_html(
    label_a: str,
    label_b: str,
    session_a: dict,
    session_b: dict,
) -> str:
    a_stats = compute_global_stats(session_a)
    b_stats = compute_global_stats(session_b)
    a_state_stats = per_state_stats(session_a)
    b_state_stats = per_state_stats(session_b)

    summary_rows = _summary_table_html(a_stats, b_stats, label_a, label_b)
    per_state_rows = _per_state_table_html(a_state_stats, b_state_stats)
    fairness_rows_html = _fairness_table_html(
        session_a["env"], session_b["env"], label_a, label_b
    )

    duration_a = round(session_a["samples"][-1]["t"] - session_a["t0"], 1)
    duration_b = round(session_b["samples"][-1]["t"] - session_b["t0"], 1)

    charts = [
        {"id": f"chart-{key}", "key": key, "title": display, "unit": unit}
        for key, display, unit, _ in METRIC_DEFS
    ]
    charts_html = "".join(
        f'<div class="chart-box"><canvas id="chart-{key}"></canvas></div>'
        for key, _, _, _ in METRIC_DEFS
    )

    js_payload = json.dumps(
        {
            "labelA": label_a,
            "labelB": label_b,
            "a": {"samples": session_a["samples"], "t0": session_a["t0"]},
            "b": {"samples": session_b["samples"], "t0": session_b["t0"]},
            "charts": charts,
        },
        separators=(",", ":"),
    )

    gen_time = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>App Profiler Comparison: {label_a} vs {label_b}</title>
<style>{_CSS}</style>
</head>
<body>
<header>
  <h1>&#x1F501; App Profiler Comparison</h1>
  <div class="meta">
    <span class="legend"><span class="swatch" style="background:#4e79a7"></span>
      <b>A</b> {label_a} ({duration_a}s, {len(session_a['samples'])} samples)</span>
    <span class="legend"><span class="swatch" style="background:#e15759"></span>
      <b>B</b> {label_b} ({duration_b}s, {len(session_b['samples'])} samples)</span>
    <span><b>Generated</b> {gen_time}</span>
  </div>
</header>

<div class="container">

<section>
  <h2>Fairness Statement</h2>
  <p class="note">⚠️ marks rows where A and B differ. Mismatches make benchmark deltas harder to attribute to the change under test.</p>
  <table>
    <thead><tr><th>Item</th><th>A: {label_a}</th><th>B: {label_b}</th></tr></thead>
    <tbody>
{fairness_rows_html}
    </tbody>
  </table>
</section>

<section>
  <h2>Global Summary</h2>
  <p class="note">Δ% is <code>(B − A) / A × 100</code>. Verdict assumes lower-is-better for CPU%, RSS, threads, FDs, and context-switch rate.</p>
  <table>
    <thead>
      <tr>
        <th>Metric</th><th>Unit</th><th>Stat</th>
        <th>A: {label_a}</th><th>B: {label_b}</th><th>Δ%</th><th>Verdict</th>
      </tr>
    </thead>
    <tbody>
{summary_rows}
    </tbody>
  </table>
</section>

<section>
  <h2>Per-state Comparison</h2>
  <p class="note">Only state labels shared between A and B are compared row-by-row. States that exist on only one side are listed at the bottom.</p>
  <table>
    <thead>
      <tr>
        <th>State</th><th>Metric</th><th>Unit</th><th>Stat</th>
        <th>A: {label_a}</th><th>B: {label_b}</th><th>Δ%</th><th>Verdict</th>
      </tr>
    </thead>
    <tbody>
{per_state_rows}
    </tbody>
  </table>
</section>

<section>
  <h2>Time-series Overlays</h2>
  <p class="note">X-axis = elapsed seconds since each session's own start. Both series are drawn on the same axes for direct visual comparison.</p>
  <div class="chart-grid">
{charts_html}
  </div>
</section>

</div>

<footer>Generated by perf-tools/scripts/compare-app-profile.py &mdash; {gen_time}</footer>

<script>
window.__CMP_DATA__ = {js_payload};
{_CHART_JS}
</script>
</body>
</html>"""


# ── CLI ──────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--a", required=True, help="path to session dir A (baseline)")
    ap.add_argument("--b", required=True, help="path to session dir B (candidate)")
    ap.add_argument("--label-a", default="", help="label for A (default: dir name)")
    ap.add_argument("--label-b", default="", help="label for B (default: dir name)")
    ap.add_argument(
        "--out", default="",
        help="output HTML path (default: ./compare_<A>_vs_<B>.html in CWD)",
    )
    args = ap.parse_args()

    dir_a = Path(args.a)
    dir_b = Path(args.b)
    session_a = load_session(dir_a)
    session_b = load_session(dir_b)

    label_a = args.label_a or dir_a.name
    label_b = args.label_b or dir_b.name

    if args.out:
        out_path = Path(args.out)
    else:
        # Sanitise labels for the default file name.
        safe_a = "".join(c if c.isalnum() or c in "-_" else "_" for c in label_a)
        safe_b = "".join(c if c.isalnum() or c in "-_" else "_" for c in label_b)
        out_path = Path.cwd() / f"compare_{safe_a}_vs_{safe_b}.html"

    html = _build_html(label_a, label_b, session_a, session_b)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(html, encoding="utf-8")
    print(f"compare-app-profile: wrote {out_path}", file=sys.stderr)
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
