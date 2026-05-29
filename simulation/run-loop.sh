#!/bin/bash
#
# simulation/run-loop.sh
# ──────────────────────
# Foreground daemon loop. Each tick fires `python -m simulation` once,
# then sleeps INTERVAL_SECONDS (default 1800 = 30 min) until the next
# tick. With 20 personas acting at most once per 15h and at most 3 per
# tick, this cadence gives the network steady, staggered activity
# without bursts.
#
# Usage:
#   nohup ./simulation/run-loop.sh > /tmp/raven-simulation.log 2>&1 &
#   echo $! > /tmp/raven-simulation.pid
#
# Or via launchd: see com.ravenmessenger.simulation.plist in this dir.
#
# Override the tick interval:
#   INTERVAL_SECONDS=900 ./simulation/run-loop.sh    # 15-min ticks

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."   # so `python -m simulation` resolves the package

# Load environment from simulation/.env (NEVER commit that file).
if [[ -f "$HERE/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$HERE/.env"
    set +a
fi

# Pick a Python: prefer the venv if one exists.
if [[ -x "$HERE/.venv/bin/python" ]]; then
    PYTHON="$HERE/.venv/bin/python"
else
    PYTHON="$(command -v python3)"
fi

INTERVAL_SECONDS="${INTERVAL_SECONDS:-1200}"   # 20 min default
echo "[run-loop] starting — interval ${INTERVAL_SECONDS}s"
echo "[run-loop] cwd=$(pwd)  python=$PYTHON"

while :; do
    NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "[run-loop] tick at $NOW_ISO"
    if ! "$PYTHON" -m simulation; then
        echo "[run-loop] tick failed (exit $?) — continuing"
    fi
    echo "[run-loop] sleeping ${INTERVAL_SECONDS}s until next tick"
    sleep "$INTERVAL_SECONDS"
done
