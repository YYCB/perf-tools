# `benchmarks/` — runnable benchmarks

Three layers, mirroring `docs/methodology.md`:

| Subdir | Layer | Examples |
|---|---|---|
| [`system/`](system/) | hardware / OS | CPU, memory, storage, network, GPU, NPU, power-thermal |
| [`ros2/`](ros2/) | ROS 2 middleware | pub/sub latency, intra-process, DDS vendors, TF2, lifecycle |
| [`e2e/`](e2e/) | end-to-end task | perception pipeline, SLAM, Nav2 control loop |

## Contract every benchmark must satisfy

1. Provide an executable `run.sh` (or `run.py`).
2. Accept at minimum:
   - `--platform=<id>` (required)
   - `--run-dir=<dir>` (optional; if omitted, call `scripts/env-snapshot.sh` to make one)
3. Write a single JSON result file `<run-dir>/<benchmark.id>.json` matching
   [`docs/result-schema.md`](../docs/result-schema.md).
4. Repeat at least 5 iterations and report `p50` + `p95` + `stdev` (see
   [`docs/methodology.md`](../docs/methodology.md)).
5. Keep a raw output file `<run-dir>/<benchmark.id>.raw.txt` for forensics.

Use [`templates/benchmark-template/`](../templates/benchmark-template/) as a starting point.

## Status

- ✅ `system/cpu/sysbench` — first end-to-end loop (M1)
- 📝 everything else — stubs, scheduled for M2/M3/M4 (see top-level README roadmap).
