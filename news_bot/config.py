"""
news_bot/config.py
==================

Runtime config. Everything pulls from environment variables so the
secrets never live in the repo. Drop a `.env` next to `main.py` (or
export via your CI / systemd unit) with:

    # ── Google Gemini ─────────────────────────────────────
    GEMINI_API_KEY=AIza...                  # from https://aistudio.google.com/apikey
    GEMINI_MODEL=gemini-2.5-flash           # cheapest model with tool use

    # ── RAVEN bot account (must already exist + be verified) ──
    # Display name in the app is "Raven News" — pick a matching username
    # at signup (e.g. `raven_news`) and use it here.
    RAVEN_BASE_URL=https://raven-server-516053629173.europe-west1.run.app
    RAVEN_BOT_USERNAME=raven_news
    RAVEN_BOT_PASSWORD=super-strong-here-from-1password

    # ── Behavior knobs ────────────────────────────────────
    MAX_POSTS_PER_RUN=5            # 5 picks per cycle, ~every 50 min via run-loop.sh
    MIN_IMPORTANCE_SCORE=6         # Gemini scores 1-10; only post >= this
    OUTPUT_LANGUAGE=en             # English by default; `fa` switches to Persian
    DEDUP_DB_PATH=./news_bot_seen.sqlite
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _required(key: str) -> str:
    val = os.environ.get(key, "").strip()
    if not val:
        raise RuntimeError(
            f"missing required env var {key} — set it in `.env` "
            f"or your systemd / cron environment."
        )
    return val


@dataclass(frozen=True)
class Config:
    # Gemini
    gemini_api_key: str
    gemini_model: str

    # RAVEN backend
    raven_base_url: str
    raven_bot_username: str
    raven_bot_password: str

    # Behavior
    max_posts_per_run: int
    min_importance_score: int
    output_language: str
    dedup_db_path: str

    @classmethod
    def load(cls) -> "Config":
        return cls(
            gemini_api_key=_required("GEMINI_API_KEY"),
            gemini_model=os.environ.get("GEMINI_MODEL", "gemini-2.5-flash"),
            raven_base_url=os.environ.get(
                "RAVEN_BASE_URL",
                "https://raven-server-516053629173.europe-west1.run.app",
            ),
            raven_bot_username=_required("RAVEN_BOT_USERNAME"),
            raven_bot_password=_required("RAVEN_BOT_PASSWORD"),
            max_posts_per_run=int(os.environ.get("MAX_POSTS_PER_RUN", "5")),
            min_importance_score=int(os.environ.get("MIN_IMPORTANCE_SCORE", "6")),
            output_language=os.environ.get("OUTPUT_LANGUAGE", "en"),
            dedup_db_path=os.environ.get("DEDUP_DB_PATH", "./news_bot_seen.sqlite"),
        )
