#!/usr/bin/env bash
# news_bot/run-loop.sh — daemon-style wrapper that runs the bot every
# 50 minutes forever. Use this when you DON'T want to manage cron /
# systemd / launchd separately.
#
# Standard cron can't express "every 50 minutes" cleanly (its minute
# field only supports fixed values + intervals that evenly divide 60),
# so we just sleep between runs ourselves.
#
# Typical install:
#
#     # foreground (test)
#     ./run-loop.sh
#
#     # detached background, log to file
#     nohup ./run-loop.sh > /tmp/raven-news-bot.log 2>&1 &
#     echo $! > /tmp/raven-news-bot.pid
#
#     # stop it later
#     kill "$(cat /tmp/raven-news-bot.pid)"
#
# Or wrap with launchd / systemd; both prefer a long-lived process to
# the cron pattern anyway. See README.md for the launchd plist.

set -uo pipefail

# Resolve our absolute location (works whether invoked as `./run-loop.sh`
# or via an absolute path from launchd).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# `python -m news_bot.main` needs PARENT_DIR on sys.path so the
# `news_bot` package resolves. Run from the parent and let Python find
# the package the normal way.
cd "$PARENT_DIR"

# Load env file. Defaults to `./.env`, but `ENV_FILE` overrides — used
# by the @raven_economic launchd plist to point at `./.env.economic`
# while still running this same script.
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ENV_FILE"
    set +a
fi

PYTHON=python3
if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python"
fi

INTERVAL_SECONDS=${INTERVAL_SECONDS:-3000}   # 50 minutes

echo "[run-loop] starting — interval ${INTERVAL_SECONDS}s ($((INTERVAL_SECONDS / 60)) min)"
echo "[run-loop] cwd=$(pwd)  python=$PYTHON"

while true; do
    started=$(date -u +%s)
    echo "[run-loop] tick at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Don't `set -e` — a single bad cycle (transient network blip,
    # Gemini 429, etc.) should NOT take the whole daemon down.
    "$PYTHON" -m news_bot.main "$@" || echo "[run-loop] tick failed (exit $?) — continuing"

    elapsed=$(( $(date -u +%s) - started ))
    remaining=$(( INTERVAL_SECONDS - elapsed ))
    if (( remaining > 0 )); then
        echo "[run-loop] sleeping ${remaining}s until next tick"
        sleep "$remaining"
    else
        echo "[run-loop] tick ran ${elapsed}s (over budget) — starting next immediately"
    fi
done
