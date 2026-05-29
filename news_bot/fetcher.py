"""
news_bot/fetcher.py
===================

Fetches every configured RSS / Atom feed in parallel and returns a
flat list of `Article` records ready to hand to the ranker.

Each feed is tolerant to network errors — a single bad source never
blocks the run. Parsing happens via `feedparser`, which handles the
~6 RSS dialects in the wild.
"""

from __future__ import annotations

import concurrent.futures
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

import feedparser

from .sources import SOURCES, NewsSource


@dataclass(frozen=True)
class Article:
    source_name: str
    source_language: str
    title: str
    summary: str          # may be HTML; ranker strips tags
    link: str             # canonical URL — also the dedup key
    published: datetime   # UTC; fallback to fetch time if feed omits
    image_url: str | None = None  # Best-effort cover image extracted from the RSS entry

    def short(self) -> str:
        """One-liner used in the ranker prompt."""
        return f"[{self.source_name}] {self.title} — {self.link}"


# ── Image extraction ──────────────────────────────────────────────────
#
# RSS / Atom feeds expose cover images through about six different
# conventions and we have to try each one. Roughly:
#
#   media:thumbnail / media:content   — Reuters, BBC, Al Jazeera, Guardian
#   enclosure (type=image/*)           — older WordPress feeds
#   itunes:image                       — podcast feeds (rare here)
#   <img src=…> in summary HTML        — fallback when nothing else
#
# feedparser flattens the namespaced tags into attribute-style names like
# `media_thumbnail`, `media_content`, `enclosures`. Each is usually a
# list of dicts with a `url` (or `href`) key.

_IMG_HTML_RE = re.compile(
    r'<img[^>]+src=["\']([^"\']+)["\']',
    re.IGNORECASE,
)


def _extract_image_url(entry) -> str | None:
    """Return the best-guess cover-image URL for an RSS entry, or None."""

    # 1. media:thumbnail — usually the editorial thumbnail
    for thumb in entry.get("media_thumbnail") or []:
        url = thumb.get("url") if isinstance(thumb, dict) else None
        if url:
            return url

    # 2. media:content (filter to image MIME types when stated)
    for media in entry.get("media_content") or []:
        if not isinstance(media, dict):
            continue
        mtype = (media.get("type") or "").lower()
        url = media.get("url")
        if url and (mtype.startswith("image/") or not mtype):
            return url

    # 3. enclosure — older but still common (e.g. some WordPress sites)
    for enc in entry.get("enclosures") or []:
        if not isinstance(enc, dict):
            continue
        href = enc.get("href") or enc.get("url")
        etype = (enc.get("type") or "").lower()
        if href and (etype.startswith("image/") or not etype):
            return href

    # 4. <img> in summary HTML — last-resort scrape
    summary = entry.get("summary") or entry.get("description") or ""
    m = _IMG_HTML_RE.search(summary)
    if m:
        return m.group(1)

    return None


def _parse_one(source: NewsSource, timeout_sec: int = 15) -> list[Article]:
    """Fetch + parse one feed. Returns [] on any error (logged, not raised)."""
    try:
        parsed = feedparser.parse(source.feed_url, request_headers={
            "User-Agent": "Mozilla/5.0 RAVEN-news-bot/1.0 (+contact: info@raven-messenger.com)",
        })
    except Exception as e:                       # network, malformed feed, etc.
        print(f"[fetcher] {source.name}: {e!s}")
        return []

    out: list[Article] = []
    for entry in parsed.entries[:25]:            # cap per-feed so we don't OOM
        title = (entry.get("title") or "").strip()
        link = (entry.get("link") or "").strip()
        if not title or not link:
            continue
        summary = (entry.get("summary") or entry.get("description") or "").strip()
        published = _entry_time(entry)
        image_url = _extract_image_url(entry)
        out.append(Article(
            source_name=source.name,
            source_language=source.language,
            title=title,
            summary=summary[:1200],               # cap so we don't spam the model
            link=link,
            published=published,
            image_url=image_url,
        ))
    return out


def _entry_time(entry) -> datetime:
    """Best-effort timezone-aware datetime for the entry."""
    for key in ("published_parsed", "updated_parsed"):
        st = entry.get(key)
        if st:
            return datetime(*st[:6], tzinfo=timezone.utc)
    return datetime.now(timezone.utc)


def fetch_all(sources: Iterable[NewsSource] = SOURCES, *, max_workers: int = 8) -> list[Article]:
    """Run every feed in parallel, return the merged list newest-first."""
    articles: list[Article] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
        for results in ex.map(_parse_one, sources):
            articles.extend(results)
    articles.sort(key=lambda a: a.published, reverse=True)
    return articles
