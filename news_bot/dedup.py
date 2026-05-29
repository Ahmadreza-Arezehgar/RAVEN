"""
news_bot/dedup.py
=================

Tracks which article URLs the bot has already published, so a cron
run that fires every hour doesn't re-post the same Reuters wire
fifty times until the headline ages out of every feed.

Simple SQLite table — easier to debug than a flat file, and we get
free atomic upserts. The DB lives next to `main.py` by default; pass
a different path via `DEDUP_DB_PATH` if you want it on a network mount.
"""

from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


SCHEMA = """
CREATE TABLE IF NOT EXISTS seen_articles (
    url           TEXT PRIMARY KEY,
    posted_at     INTEGER NOT NULL,
    source        TEXT,
    headline      TEXT,
    raven_post_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_posted_at ON seen_articles(posted_at);
"""


class SeenStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as c:
            c.executescript(SCHEMA)

    @contextmanager
    def _conn(self):
        # `check_same_thread=False` because we may run inside a worker; the
        # bot is single-threaded today but cheap to keep flexible.
        conn = sqlite3.connect(self.path, check_same_thread=False)
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def has(self, url: str) -> bool:
        with self._conn() as c:
            cur = c.execute("SELECT 1 FROM seen_articles WHERE url = ? LIMIT 1", (url,))
            return cur.fetchone() is not None

    def mark(self, url: str, *, source: str = "", headline: str = "", raven_post_id: str = "") -> None:
        """Idempotent — re-marking the same url just updates the timestamp."""
        with self._conn() as c:
            c.execute(
                "INSERT OR REPLACE INTO seen_articles "
                "(url, posted_at, source, headline, raven_post_id) "
                "VALUES (?, ?, ?, ?, ?)",
                (url, int(time.time()), source, headline, raven_post_id),
            )

    def prune_older_than(self, days: int = 30) -> int:
        """Drop rows older than `days`. Returns number deleted."""
        cutoff = int(time.time()) - days * 86_400
        with self._conn() as c:
            cur = c.execute("DELETE FROM seen_articles WHERE posted_at < ?", (cutoff,))
            return cur.rowcount or 0
