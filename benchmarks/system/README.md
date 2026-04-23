# `benchmarks/system/` — hardware / OS layer

| Subdir | Tools | Status |
|---|---|---|
| [`cpu/`](cpu/) | sysbench, stress-ng, coremark, 7zip | sysbench ✅ (M1); rest M2 |
| [`memory/`](memory/) | stream, mbw, lmbench, tinymembench | M2 |
| [`storage/`](storage/) | fio, iozone | M2 |
| [`network/`](network/) | iperf3, netperf, sockperf | M2 |
| [`gpu/`](gpu/) | clpeak, cuda-samples, glmark2 | M2 |
| [`npu/`](npu/) | trtexec (NV), HBDK tools (Horizon), rknn-toolkit (Rockchip) | M2 |
| [`power-thermal/`](power-thermal/) | tegrastats, powertop, INA226 sampling | M2 |
