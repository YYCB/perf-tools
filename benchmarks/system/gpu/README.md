# `system/gpu`

GPU compute benchmark.

> ⚠️ **Hardware required**: a GPU with compute capability (NVIDIA CUDA, ARM Mali, or equivalent).

## Planned metrics

| Metric | Unit | Tool |
|---|---|---|
| FP32 TFLOPS | TFLOPS | `nvbandwidth` / `clpeak` / custom CUDA/OpenCL kernel |
| FP16 TFLOPS | TFLOPS | same |
| GPU memory bandwidth | GB/s | `nvbandwidth` |
| Tensor core TOPS (INT8) | TOPS | `trtexec` |

## Status

📝 **Not yet implemented.** GPU benchmark is hardware-gated.

To implement: copy [`templates/benchmark-template/`](../../../templates/benchmark-template/)
and add a `run.sh` that:
1. Detects platform (NVIDIA: `nvidia-smi`, ARM: `clinfo`, Qualcomm: `qnn-net-run`)
2. Runs the appropriate compute test
3. Outputs `system.gpu.json` with `fp32_tflops`, `fp16_tflops`, `bandwidth_gb_s`

## Workaround: NPU as proxy

For Jetson and Horizon platforms, `system/npu` already measures INT8 inference
throughput which is often the most relevant metric for robot workloads:

```bash
./benchmarks/system/npu/run.sh --platform=orin --model=model.onnx
```

