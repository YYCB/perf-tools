# Benchmark Template

Copy this directory into `benchmarks/<layer>/<topic>/<your-bench-name>/` and edit:

```bash
cp -r templates/benchmark-template benchmarks/system/cpu/coremark
cd benchmarks/system/cpu/coremark
$EDITOR run.sh README.md
```

## What you must do

1. Set `BENCH_ID` in `run.sh` to a dotted ID matching the directory path,
   e.g. `system.cpu.coremark`.
2. Replace the sample workload (the `sleep` call) with your real benchmark
   command. Parse its output and append one numeric sample per iteration to
   `${SAMPLES_FILE}`.
3. Update the `metrics` block in the embedded Python — the metric name and
   `unit` should reflect what you measured (`latency_us`, `throughput`,
   `bandwidth_mb_s`, etc.). See [`docs/metrics-glossary.md`](../../docs/metrics-glossary.md).
4. Fill in this `README.md`: what / why / knobs / output / caveats (mirror
   `benchmarks/system/cpu/sysbench/README.md` as the canonical example).

## What you get for free

- Argument parsing (`--platform`, `--run-dir`, `--threads`, `--duration`, `--iterations`, `--warmup`)
- Auto env-snapshot if `--run-dir` is omitted
- Output JSON conforming to [`docs/result-schema.md`](../../docs/result-schema.md)
- Raw output captured alongside JSON
- Statistics (p50/p95/min/max/avg/stdev) computed from your samples

## Contract reminder

Always:
- Run ≥ 5 iterations
- Discard a warm-up window
- Emit JSON with `p50` + `unit` for every metric
- Keep raw output (`<bench>.raw.txt`)
