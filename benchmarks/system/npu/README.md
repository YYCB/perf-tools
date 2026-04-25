# `system/npu`

NPU inference throughput and latency benchmark.  Dispatches to the right tool
for each platform so that the JSON output is always in the same schema.

## Platform dispatch

| Platform | Tool | Model format |
|---|---|---|
| `orin` | `trtexec` (JetPack TensorRT) | ONNX → compiled TRT engine |
| `s100` | `hb_perf` (HBDK / Compass SDK) | Pre-compiled `.bin` |
| other | `onnxruntime` CPU (fallback) | ONNX |

## Quick start

```bash
# Orin
./benchmarks/system/npu/run.sh \
    --platform=orin \
    --model=/path/to/resnet50.onnx \
    --batch=1 --precision=fp16

# S100
./benchmarks/system/npu/run.sh \
    --platform=s100 \
    --model=/path/to/resnet50.bin \
    --batch=1
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--platform=<id>` | _required_ | orin / s100 / x86 / … |
| `--model=<path>` | _required_ | Path to model file |
| `--run-dir=<dir>` | auto | Reuse an existing run directory |
| `--batch=N` | 1 | Batch size |
| `--iterations=N` | 100 | Inference iterations to measure |
| `--warmup=N` | 20 | Iterations to discard |
| `--precision=…` | fp16 | Orin only: fp32 / fp16 / int8 |

## Output metrics

| Metric | Unit | Description |
|---|---|---|
| `inference_latency` | us (Orin) / ms (others) | p50/p95/p99/min/max/avg/stdev |
| `throughput_fps_derived` | fps | batch / avg_latency |
| `throughput_qps` / `throughput_fps` | qps / fps | Direct tool measurement (if available) |

## Notes

- For a fair Orin vs S100 comparison, use the **same model architecture** and
  **same batch size** on both platforms.
- Orin: convert your ONNX to TRT engine at the desired precision before
  comparing; `--precision=fp16` is the recommended starting point.
- S100: `hb_perf` requires a pre-compiled `.bin` from the HBDK toolchain.
