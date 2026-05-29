"""
news_bot/main.py
================

Single-shot orchestrator. One run does this:

  1. Fetch every configured RSS feed (in parallel).
  2. Drop articles we've already published (SQLite dedup).
  3. Ask Gemini 2.5 Flash to rank + summarize the rest.
  4. Publish the top N picks to RAVEN as posts.
  5. Mark every published URL as seen so we don't re-publish.

Run interactively for testing:

    cd /Users/ahmd/hybrid_messenger/news_bot
    python -m news_bot.main           # full run
    python -m news_bot.main --dry-run # ranker + render, no actual POST

Schedule via cron / launchd / systemd timer — see `run.sh` for an
example wrapper. Once per hour is the sweet spot: enough freshness
for breaking news, sparse enough that the channel doesn't spam.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime

from .config import Config
from .dedup import SeenStore
from .fetcher import fetch_all
from .poster import RavenPoster, PosterError
from .ranker import rank_and_summarize


def run(dry_run: bool = False, verbose: bool = False) -> int:
    cfg = Config.load()
    log = (lambda *a, **k: None) if not verbose else print

    print(f"[bot] starting at {datetime.utcnow().isoformat()}Z")

    # ── 1. Fetch every feed ────────────────────────────────────────
    articles = fetch_all()
    if not articles:
        print("[bot] no articles fetched — nothing to do")
        return 0
    log(f"[bot] fetched {len(articles)} articles across feeds")

    # ── 2. Dedup against the SQLite seen-store ─────────────────────
    seen = SeenStore(cfg.dedup_db_path)
    fresh = [a for a in articles if not seen.has(a.link)]
    log(f"[bot] {len(fresh)} fresh after dedup ({len(articles) - len(fresh)} already posted)")
    if not fresh:
        return 0

    # ── 3. Ask Gemini to rank + summarize ──────────────────────────
    picks = rank_and_summarize(fresh, cfg)
    log(f"[bot] Gemini returned {len(picks)} picks")
    if not picks:
        print("[bot] no picks met the importance threshold — quiet day")
        return 0

    # Show what we'd publish in the log regardless of dry-run.
    for p in picks:
        print(f"  • [{p.importance}/10] {p.headline}  ←  {p.source}")

    if dry_run:
        print("[bot] --dry-run set; skipping POST + dedup mark")
        return 0

    # ── 4. Publish to RAVEN ────────────────────────────────────────
    posted = 0
    try:
        with RavenPoster(cfg) as poster:
            for p in picks:
                result = poster.publish(p)
                if result.ok:
                    seen.mark(p.url, source=p.source, headline=p.headline,
                              raven_post_id=result.raven_post_id or "")
                    posted += 1
                    log(f"[bot] posted {result.raven_post_id} — {p.headline[:60]}")
                else:
                    print(f"[bot] FAILED to post {p.url}: {result.error}")
    except PosterError as e:
        print(f"[bot] auth/network error: {e}", file=sys.stderr)
        return 2

    print(f"[bot] done — published {posted}/{len(picks)} picks")
    return 0


def cli() -> None:
    parser = argparse.ArgumentParser(description="RAVEN political news bot")
    parser.add_argument("--dry-run", action="store_true",
                        help="rank + render only; don't POST to RAVEN or update dedup")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="print each step to stdout")
    args = parser.parse_args()
    sys.exit(run(dry_run=args.dry_run, verbose=args.verbose))


if __name__ == "__main__":
    cli()
