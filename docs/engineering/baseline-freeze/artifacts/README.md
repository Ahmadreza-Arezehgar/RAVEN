# Baseline-freeze harvest dumps

Timestamped stdout from [`node/scripts/harvest_perf_baseline.sh`](../../../node/scripts/harvest_perf_baseline.sh).

| Directory | Toolchain | Verdict |
|-----------|-----------|---------|
| [`20260904T111245Z-2038/`](20260904T111245Z-2038/) | rustc 1.83.0 | `HARVEST_FAILED` (`kem v0.3.0` / `edition2024`) |
| [`20260904T111355Z-2345/`](20260904T111355Z-2345/) | rustc 1.98.1 | `HARVEST_OK` — source for [`perf-baseline-2026-09-04.md`](../perf-baseline-2026-09-04.md) |

These files are raw cargo captures, not soak pass rates.
