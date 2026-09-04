#!/usr/bin/env bash
# Harvest Sprint 0 performance-baseline stdout from existing raven-core gates.
#
# This script does not invent, estimate, or derive metrics. It runs the same
# cargo tests already wired as CI gates and writes their full --nocapture
# stdout/stderr (plus a short host header) to a timestamped artifact.
# Exit 0 only if every requested test succeeded. A failed test is recorded
# and the script exits non-zero — it never claims green on failure.
#
# Usage (from node/ or via this path):
#   ./scripts/harvest_perf_baseline.sh
#   RAVEN_PERF_RELEASE=1 ./scripts/harvest_perf_baseline.sh
#   RAVEN_RELIABILITY_10K=1 ./scripts/harvest_perf_baseline.sh
#   RAVEN_RELIABILITY_10K=1 RAVEN_RELIABILITY_10K_RUNS=3 ./scripts/harvest_perf_baseline.sh
#
# Environment:
#   RAVEN_PERF_RELEASE          set to 1 to also run network_sim_1000 --release
#   RAVEN_RELIABILITY_10K       set to 1 to run the ignored reliability_10k test
#   RAVEN_RELIABILITY_10K_RUNS  repeat count for reliability_10k (default 1)
#   RAVEN_PERF_ARTIFACT_DIR     override artifact directory
#
# Artifacts:
#   <repo>/docs/engineering/baseline-freeze/artifacts/<utc>-<pid>/
#     HEADER.txt
#     network_sim_1000.debug.stdout.txt
#     network_sim_1000.release.stdout.txt   (if RAVEN_PERF_RELEASE=1)
#     reliability_10k.runN.stdout.txt       (if RAVEN_RELIABILITY_10K=1)
#     STATUS.txt
#
# The same cargo output is also streamed to stdout for redirect.
#
# Toolchain: cargo must parse current crates.io manifests. rustc 1.83.0 failed
# on this host (kem 0.3.0 requires edition2024). Use current stable (CI uses
# dtolnay/rust-toolchain@stable), documented in the harvest HEADER.txt.
set -euo pipefail

NODE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$NODE_ROOT/.." && pwd)"
cd "$NODE_ROOT"

source "${HOME}/.cargo/env" 2>/dev/null || true

UTC="$(date -u +%Y%m%dT%H%M%SZ)"
ART="${RAVEN_PERF_ARTIFACT_DIR:-$REPO_ROOT/docs/engineering/baseline-freeze/artifacts/${UTC}-$$}"
mkdir -p "$ART"

STATUS=0
REQUESTED=0
PASSED=0
FAILED=0

header() {
  {
    echo "harvest_perf_baseline"
    echo "utc=${UTC}"
    echo "pid=$$"
    echo "repo=${REPO_ROOT}"
    echo "cwd=${NODE_ROOT}"
    echo "host=$(uname -s) $(uname -r) $(uname -m)"
    echo "hostname=$(hostname)"
    if command -v rustc >/dev/null 2>&1; then
      echo "rustc=$(rustc --version)"
    else
      echo "rustc=NOT FOUND"
    fi
    if command -v cargo >/dev/null 2>&1; then
      echo "cargo=$(cargo --version)"
    else
      echo "cargo=NOT FOUND"
    fi
    echo "nproc=$(nproc 2>/dev/null || echo unknown)"
    echo "RAVEN_PERF_RELEASE=${RAVEN_PERF_RELEASE:-0}"
    echo "RAVEN_RELIABILITY_10K=${RAVEN_RELIABILITY_10K:-0}"
    echo "RAVEN_RELIABILITY_10K_RUNS=${RAVEN_RELIABILITY_10K_RUNS:-1}"
  } | tee "$ART/HEADER.txt"
}

run_gate() {
  local label="$1"
  local out="$2"
  shift 2
  REQUESTED=$((REQUESTED + 1))
  echo
  echo "======== BEGIN ${label} ========"
  echo "command: $*"
  local rc=0
  set +e
  "$@" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  echo "======== END ${label} exit=${rc} ========"
  echo "exit=${rc}" >>"$out"
  if [[ "$rc" -eq 0 ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    STATUS=1
  fi
  return 0
}

header

run_gate "network_sim_1000.debug" \
  "$ART/network_sim_1000.debug.stdout.txt" \
  cargo test -p raven-core --test network_sim_1000 -- --nocapture

if [[ "${RAVEN_PERF_RELEASE:-0}" == "1" ]]; then
  run_gate "network_sim_1000.release" \
    "$ART/network_sim_1000.release.stdout.txt" \
    cargo test --release -p raven-core --test network_sim_1000 -- --nocapture
fi

if [[ "${RAVEN_RELIABILITY_10K:-0}" == "1" ]]; then
  runs="${RAVEN_RELIABILITY_10K_RUNS:-1}"
  if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
    echo "RAVEN_RELIABILITY_10K_RUNS must be a positive integer" >&2
    exit 1
  fi
  for i in $(seq 1 "$runs"); do
    run_gate "reliability_10k.run${i}" \
      "$ART/reliability_10k.run${i}.stdout.txt" \
      cargo test -p raven-core --test reliability_10k -- --nocapture --ignored
  done
fi

{
  echo "requested=${REQUESTED}"
  echo "passed=${PASSED}"
  echo "failed=${FAILED}"
  if [[ "$STATUS" -eq 0 ]]; then
    echo "verdict=HARVEST_OK"
  else
    echo "verdict=HARVEST_FAILED"
  fi
  echo "artifact_dir=${ART}"
} | tee "$ART/STATUS.txt"

echo
echo "harvest artifacts: ${ART}"
if [[ "$STATUS" -ne 0 ]]; then
  echo "harvest failed: ${FAILED} of ${REQUESTED} requested gate(s) failed" >&2
fi
exit "$STATUS"
