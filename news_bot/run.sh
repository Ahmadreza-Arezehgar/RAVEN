#!/usr/bin/env bash
# news_bot/run.sh — cron-friendly wrapper.
#
# Add this to your crontab (or systemd timer / launchd plist) to run
# the bot every hour at minute 7:
#
#     7 * * * * /Users/ahmd/hybrid_messenger/news_bot/run.sh >> /tmp/raven-news-bot.log 2>&1
#
# `crontab -e` to install. The minute offset spreads load away from
# common feeds-update minutes (00, 30) so we catch their freshly-cached
# feeds.
#
# Required env vars must be set BEFORE this script runs. The easiest
# pattern: put them in `.env` next to this file and uncomment the
# `set -a; source ./.env; set +a` line below. Don't commit `.env`.

set -euo pipefail

cd "$(dirname "$0")"

# Source secrets from a sibling .env if it exists. Marker-style so a
# fresh checkout fails loudly if you forgot to create it.
if [[ -f ./.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source ./.env
    set +a
fi

# Use the venv if present (better isolation than the system Python).
PYTHON=python3
if [[ -x ./.venv/bin/python ]]; then
    PYTHON=./.venv/bin/python
fi

exec "$PYTHON" -m news_bot.main "$@"
