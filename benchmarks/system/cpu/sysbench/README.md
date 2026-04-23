# `system.cpu.sysbench`

Single-host CPU throughput benchmark using [`sysbench`](https://github.com/akopytov/sysbench)
(`cpu` workload — finds primes up to `cpu-max-prime`).

## Why

- Available on every Debian / Ubuntu derivative (`apt install sysbench`)
- Stable, single number per iteration (`events per second`)
- Good baseline / smoke test before bigger CPU suites (coremark, 7zip, stress-ng)

## Run

```bash
./run.sh --platform=orin
# or with explicit knobs:
./run.sh --platform=orin --threads=8 --duration=30 --iterations=5
```

## Knobs

| Flag | Default | Meaning |
|---|---|---|
| `--platform` | (required) | platform id, used in result paths |
| `--run-dir` | (auto) | reuse a pre-created run dir; if omitted, calls `env-snapshot.sh` |
| `--threads` | `nproc` | sysbench `--threads` |
| `--duration` | `10` | seconds per iteration |
| `--iterations` | `5` | independent runs (>=5 recommended) |
| `--warmup` | `3` | discarded warmup seconds |
| `--prime` | `20000` | sysbench `--cpu-max-prime` |

## Output

- `<run-dir>/system.cpu.sysbench.json` — schema per `docs/result-schema.md`
- `<run-dir>/system.cpu.sysbench.raw.txt` — raw sysbench stdout

The primary metric is `events_per_sec` (higher is better) reported as
`{p50, p95, min, max, avg, stdev}` over the iterations.

## Caveats

- `sysbench cpu` is integer-heavy and hits L1/L2 well — it does **not**
  represent memory-bandwidth-bound or float-heavy workloads. Pair with
  `stream`/`mbw` and a vector benchmark for a fuller picture.
- Result depends heavily on CPU governor and frequency lock. See
  [`docs/playbooks/linux-rt-tuning.md`](../../../../docs/playbooks/linux-rt-tuning.md).
