#!/usr/bin/env python3
"""trend.py — plot metric trends across multiple runs of the same platform.

Usage:
    python3 scripts/trend.py \
        --platform=orin \
        [--results-dir=results] \
        [--metrics=system.cpu.sysbench::events_per_sec,system.memory::bandwidth] \
        [--out=reports/orin-trend.html] \
        [--last=20]              # only the most recent N runs

Behaviour:
- Reads results/<platform>/index.json (produced by collect-results.py).
- Loads the p50 value for each requested (benchmark, metric) pair from every run.
- Generates a self-contained HTML with time-series line charts (vanilla JS/Canvas).
- If --metrics is omitted, plots all metrics found across all runs.

Output:
    A single self-contained HTML file (no external deps) you can open offline.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent


def load_index(results_dir: Path, platform: str) -> dict[str, Any]:
    idx_path = results_dir / platform / "index.json"
    if not idx_path.exists():
        sys.exit(
            f"ERROR: index not found at {idx_path}.\n"
            f"Run: python3 scripts/collect-results.py --platform={platform}"
        )
    return json.loads(idx_path.read_text(encoding="utf-8"))


def load_metric_value(run_dir: Path, benchmark_id: str, metric_name: str) -> float | None:
    # Try .json file named after benchmark_id (dots kept)
    jf = run_dir / f"{benchmark_id}.json"
    if not jf.exists():
        return None
    try:
        doc = json.loads(jf.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    m = doc.get("metrics", {}).get(metric_name)
    if not isinstance(m, dict):
        return None
    for k in ("p50", "avg", "p95", "p99", "max"):
        v = m.get(k)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def collect_series(
    results_dir: Path,
    platform: str,
    requested: list[tuple[str, str]] | None,
    last: int,
) -> dict[str, list[tuple[str, float]]]:
    """Returns {series_key: [(run_id, value), ...]} sorted by run_id (timestamp)."""
    idx = load_index(results_dir, platform)
    runs = sorted(idx.get("runs", []), key=lambda r: r.get("run_id", ""))
    if last > 0:
        runs = runs[-last:]

    # Auto-discover metrics if not specified
    if not requested:
        keys: set[tuple[str, str]] = set()
        for r in runs:
            for b in r.get("benchmarks", []):
                bid = b.get("id") or ""
                for mname in b.get("metrics", []):
                    keys.add((bid, mname))
        requested = sorted(keys)

    series: dict[str, list[tuple[str, float]]] = {}
    for bid, mname in requested:
        key = f"{bid}::{mname}"
        series[key] = []
        for r in runs:
            run_id = r.get("run_id", "?")
            run_path = results_dir / platform / run_id
            v = load_metric_value(run_path, bid, mname)
            if v is not None:
                series[key].append((run_id, v))
    # Remove empty series
    series = {k: v for k, v in series.items() if v}
    return series


def _js_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")


def render_html(
    platform: str,
    series: dict[str, list[tuple[str, float]]],
    title: str,
) -> str:
    # Collect all run_ids in order
    all_runs: list[str] = []
    seen: set[str] = set()
    for pts in series.values():
        for rid, _ in pts:
            if rid not in seen:
                all_runs.append(rid)
                seen.add(rid)
    all_runs.sort()

    # Build per-series data aligned to all_runs
    series_js_parts: list[str] = []
    colours = [
        "#2980b9", "#e74c3c", "#2ecc71", "#f39c12", "#9b59b6",
        "#1abc9c", "#e67e22", "#34495e", "#c0392b", "#27ae60",
    ]
    for i, (key, pts) in enumerate(series.items()):
        run_map = {rid: v for rid, v in pts}
        vals_js = ", ".join(
            str(run_map[r]) if r in run_map else "null"
            for r in all_runs
        )
        colour = colours[i % len(colours)]
        short_key = _js_escape(key)
        series_js_parts.append(
            f"  {{ label: '{short_key}', data: [{vals_js}], "
            f"colour: '{colour}' }}"
        )

    labels_js = ", ".join(f"'{_js_escape(r)}'" for r in all_runs)
    series_js = "[\n" + ",\n".join(series_js_parts) + "\n]"

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{platform} — Performance Trend</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 0; padding: 16px; background: #f8f9fa; }}
  h1 {{ font-size: 1.4em; margin-bottom: 4px; }}
  h2 {{ font-size: 1em; color: #555; margin-top: 24px; margin-bottom: 4px; }}
  canvas {{ background: white; border: 1px solid #ddd; border-radius: 4px; }}
  .legend {{ margin-top: 4px; font-size: 0.8em; color: #333; }}
  .legend span {{ display: inline-block; width: 12px; height: 12px;
                  border-radius: 2px; margin-right: 4px; vertical-align: middle; }}
</style>
</head>
<body>
<h1>📈 {platform} — Performance Trend</h1>
<p style="color:#666;font-size:.85em">{len(series)} metric(s) · {len(all_runs)} run(s)</p>

<div id="charts"></div>

<script>
const ALL_LABELS = [{labels_js}];
const ALL_SERIES = {series_js};

function drawChart(containerId, label, data, colour) {{
  const W = 900, H = 260, PAD = {{top:20, right:20, bottom:80, left:70}};
  const cw = W - PAD.left - PAD.right;
  const ch = H - PAD.top  - PAD.bottom;

  const c = document.createElement('canvas');
  c.width = W; c.height = H;
  const ctx = c.getContext('2d');

  const valid = data.map((v,i)=>v!==null ? {{i,v}} : null).filter(Boolean);
  if (!valid.length) return;

  const ymin = Math.min(...valid.map(p=>p.v));
  const ymax = Math.max(...valid.map(p=>p.v));
  const ypad = (ymax - ymin) * 0.1 || Math.abs(ymin) * 0.1 || 1;
  const ylo = ymin - ypad, yhi = ymax + ypad;

  function xpos(i) {{ return PAD.left + (i / (ALL_LABELS.length - 1 || 1)) * cw; }}
  function ypos(v) {{ return PAD.top + ch - ((v - ylo) / (yhi - ylo)) * ch; }}

  // grid
  ctx.strokeStyle = '#eee'; ctx.lineWidth = 1;
  for (let k=0; k<=4; k++) {{
    const y = PAD.top + ch * k / 4;
    ctx.beginPath(); ctx.moveTo(PAD.left, y); ctx.lineTo(PAD.left + cw, y); ctx.stroke();
    const val = yhi - (yhi - ylo) * k / 4;
    ctx.fillStyle='#999'; ctx.font='11px system-ui'; ctx.textAlign='right';
    ctx.fillText(val.toPrecision(4), PAD.left - 6, y + 4);
  }}

  // line
  ctx.strokeStyle = colour; ctx.lineWidth = 2;
  ctx.beginPath();
  let first = true;
  for (const p of valid) {{
    const x = xpos(p.i), y = ypos(p.v);
    if (first) {{ ctx.moveTo(x, y); first = false; }} else ctx.lineTo(x, y);
  }}
  ctx.stroke();

  // dots
  ctx.fillStyle = colour;
  for (const p of valid) {{
    ctx.beginPath(); ctx.arc(xpos(p.i), ypos(p.v), 3, 0, 2*Math.PI); ctx.fill();
  }}

  // x labels
  ctx.fillStyle = '#555'; ctx.font = '10px system-ui'; ctx.textAlign = 'center';
  for (let i=0; i<ALL_LABELS.length; i++) {{
    const x = xpos(i);
    ctx.save(); ctx.translate(x, PAD.top + ch + 6);
    ctx.rotate(-Math.PI/3);
    ctx.textAlign = 'right';
    ctx.fillText(ALL_LABELS[i].slice(0,26), 0, 0);
    ctx.restore();
  }}

  const wrapper = document.createElement('div');
  wrapper.style.marginBottom = '24px';
  const title = document.createElement('h2');
  title.textContent = label;
  wrapper.appendChild(title);
  wrapper.appendChild(c);
  document.getElementById('charts').appendChild(wrapper);
}}

ALL_SERIES.forEach(s => drawChart('charts', s.label, s.data, s.colour));
</script>
</body>
</html>"""
    return html


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--platform", required=True, help="platform id")
    ap.add_argument("--results-dir", default=str(ROOT / "results"),
                    help="root results directory")
    ap.add_argument("--metrics", default="",
                    help="comma-separated list of 'benchmark::metric' pairs "
                         "(default: all discovered)")
    ap.add_argument("--last", type=int, default=0,
                    help="only plot the N most recent runs (0 = all)")
    ap.add_argument("--out", required=True, help="output HTML path")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)

    requested: list[tuple[str, str]] | None = None
    if args.metrics:
        requested = []
        for tok in args.metrics.split(","):
            tok = tok.strip()
            if "::" in tok:
                bench, _, metric = tok.partition("::")
                requested.append((bench.strip(), metric.strip()))
            else:
                print(f"WARN: ignoring malformed metric spec '{tok}' "
                      "(expected 'benchmark::metric')", file=sys.stderr)

    series = collect_series(results_dir, args.platform, requested, args.last)
    if not series:
        print("WARN: no trend data found — run collect-results.py first",
              file=sys.stderr)
        return 0

    html = render_html(args.platform, series, f"{args.platform} trend")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print(f"wrote {out}  ({len(series)} series, {len(set(r for pts in series.values() for r,_ in pts))} runs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
