#!/usr/bin/env bash
# Opt-in 10k message reliability (queue + dedup). Slow on HDDs; skip in default CI.
# Usage: RAVEN_RELIABILITY_10K=1 ./scripts/reliability_10k.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${RAVEN_RELIABILITY_10K:-}" != "1" ]]; then
  echo "Set RAVEN_RELIABILITY_10K=1 to run the 10k reliability harness."
  echo "Running 1k subset via cargo test instead..."
  cargo test -p raven-core --test fuzz_smoke scale_1k -- --nocapture
  exit 0
fi
cargo test -p raven-core --test reliability_10k -- --nocapture --ignored
