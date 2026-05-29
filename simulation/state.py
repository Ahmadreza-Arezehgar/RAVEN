"""
simulation/state.py
===================

Per-persona persistent state. Stored in a tiny SQLite file so the
daemon survives reboots / cold starts without re-registering anyone or
double-acting.

Tables
------
personas
    One row per persona. Owns the username → user_id mapping, the
    auto-generated password, and the action counters.

seen_posts
    Records (persona, post_id, action) so a persona doesn't reply to
    the same post twice or like a post they already liked. The action
    column distinguishes "viewed", "liked", "replied".

cycle_log
    Append-only ledger of "persona X did action Y at time Z (target
    post P)" — useful for debugging, dashboards, and rate-control
    audits. Trimmed to last 10k rows on every write to bound size.
"""

from __future__ import annotations

import os
import secrets
import sqlite3
import string
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, List, Optional


DEFAULT_DB_PATH = Path(__file__).resolve().parent / "simulation_state.sqlite"


@dataclass
class PersonaRow:
    username: str
    user_id: Optional[str]
    password: str
    registered_at: Optional[int]
    last_action_at: Optional[int]     # any action — view / like / reply / post
    last_post_at: Optional[int]       # 🆕 just POSTS — governs the 15h post cadence
    last_social_at: Optional[int]     # 🆕 reply OR like — governs the 3h social cadence
    total_posts: int
    total_replies: int
    total_likes: int
    total_views: int
    # 🆕 2026-05-23 — social-graph seeding. 0 = persona has never seeded
    # its initial follow / friend-request set against other personas.
    # The orchestrator does this ONCE per persona (a few follows + a
    # friend request or two) so `UserFollow` and `FriendRequest` carry
    # real edges and the network feels populated. Subsequent graph
    # growth happens organically through `_do_graph_action` if added.
    graph_bootstrapped: int = 0


def _generate_password(username: str) -> str:
    """Make a fresh password that satisfies RAVEN's strong policy.

    Policy (server/routers/auth.py:validate_password):
      • ≥10 chars, ≥1 upper, ≥1 lower, ≥1 digit, ≥1 special,
        not containing the username, not in COMMON_PASSWORDS.

    We force one of each required class up front, then pad with a
    larger random tail. Final string is shuffled so the structure
    isn't predictable.
    """
    upper = secrets.choice(string.ascii_uppercase)
    lower = secrets.choice(string.ascii_lowercase)
    digit = secrets.choice(string.digits)
    special = secrets.choice("!@#$%^&*()_+-=[]{}/?.,<>:;")
    # 14 chars of additional randomness; total length ≥ 18.
    tail = "".join(
        secrets.choice(string.ascii_letters + string.digits + "!@#$%^&*-_")
        for _ in range(14)
    )
    pieces = [upper, lower, digit, special] + list(tail)
    # Shuffle deterministically via secrets-driven swaps.
    for i in range(len(pieces) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        pieces[i], pieces[j] = pieces[j], pieces[i]
    pw = "".join(pieces)
    # Defense: if our shuffle ever produced the username as a
    # substring (probability ≈ 0 but worth checking), rerun.
    if username.lower() in pw.lower():
        return _generate_password(username)
    return pw


class StateStore:
    """Tiny SQLite-backed state. One connection per call, autocommit
    when used via the `transaction()` ctx manager. Safe enough for
    our single-writer daemon."""

    def __init__(self, db_path: Path | str = DEFAULT_DB_PATH):
        self.db_path = str(db_path)
        self._init_schema()

    # ── Connection helpers ─────────────────────────────────────────

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, isolation_level=None)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
        finally:
            conn.close()

    def _init_schema(self) -> None:
        with self.transaction() as conn:
            conn.executescript("""
            CREATE TABLE IF NOT EXISTS personas (
                username        TEXT PRIMARY KEY,
                user_id         TEXT,
                password        TEXT NOT NULL,
                registered_at   INTEGER,
                last_action_at  INTEGER,
                last_post_at    INTEGER,
                last_social_at  INTEGER,
                total_posts     INTEGER NOT NULL DEFAULT 0,
                total_replies   INTEGER NOT NULL DEFAULT 0,
                total_likes     INTEGER NOT NULL DEFAULT 0,
                total_views     INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS seen_posts (
                username  TEXT NOT NULL,
                post_id   TEXT NOT NULL,
                action    TEXT NOT NULL,
                at        INTEGER NOT NULL,
                PRIMARY KEY (username, post_id, action)
            );
            CREATE INDEX IF NOT EXISTS idx_seen_username ON seen_posts(username);

            CREATE TABLE IF NOT EXISTS cycle_log (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                at        INTEGER NOT NULL,
                username  TEXT NOT NULL,
                action    TEXT NOT NULL,
                target    TEXT,
                detail    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_log_at ON cycle_log(at DESC);
            """)
            # Idempotent schema upgrade for existing DBs that pre-date the
            # split between post-cadence and social-cadence (added 2026-05-20).
            for ddl in (
                "ALTER TABLE personas ADD COLUMN last_post_at INTEGER",
                "ALTER TABLE personas ADD COLUMN last_social_at INTEGER",
                # 🆕 2026-05-23 — graph-bootstrap marker.
                "ALTER TABLE personas ADD COLUMN graph_bootstrapped INTEGER NOT NULL DEFAULT 0",
            ):
                try:
                    conn.execute(ddl)
                except sqlite3.OperationalError:
                    pass  # column already exists

    # ── Persona row CRUD ───────────────────────────────────────────

    def ensure_persona(self, username: str) -> PersonaRow:
        """Insert a stub row with a fresh password if none exists.
        Returns the current row either way."""
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT username, user_id, password, registered_at, "
                "last_action_at, last_post_at, last_social_at, "
                "total_posts, total_replies, total_likes, total_views, "
                "graph_bootstrapped "
                "FROM personas WHERE username = ?",
                (username,),
            ).fetchone()
            if row is None:
                pw = _generate_password(username)
                conn.execute(
                    "INSERT INTO personas (username, password) VALUES (?, ?)",
                    (username, pw),
                )
                return PersonaRow(
                    username=username, user_id=None, password=pw,
                    registered_at=None, last_action_at=None,
                    last_post_at=None, last_social_at=None,
                    total_posts=0, total_replies=0, total_likes=0, total_views=0,
                    graph_bootstrapped=0,
                )
            return PersonaRow(*row)

    def mark_registered(self, username: str, user_id: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                "UPDATE personas SET user_id = ?, registered_at = ? "
                "WHERE username = ?",
                (user_id, int(time.time()), username),
            )

    def mark_action(self, username: str, kind: str) -> None:
        """kind ∈ {'post', 'reply', 'like', 'view'} — increments the
        counter AND stamps the right cadence column(s).

        Cadence rules (added 2026-05-20):
          • post     → bumps last_action_at AND last_post_at
                       (governs the 15-hour post window)
          • reply    → bumps last_action_at AND last_social_at
                       (governs the ~3-hour social window)
          • like     → bumps last_action_at AND last_social_at
          • view     → bumps last_action_at (counts as "alive" but
                       never gates anything by itself)
        """
        counter = {
            "post": "total_posts",
            "reply": "total_replies",
            "like": "total_likes",
            "view": "total_views",
        }.get(kind)
        if counter is None:
            return
        extra_col = {
            "post": "last_post_at",
            "reply": "last_social_at",
            "like": "last_social_at",
        }.get(kind)
        now = int(time.time())
        with self.transaction() as conn:
            if extra_col:
                conn.execute(
                    f"UPDATE personas SET {counter} = {counter} + 1, "
                    f"last_action_at = ?, {extra_col} = ? WHERE username = ?",
                    (now, now, username),
                )
            else:
                conn.execute(
                    f"UPDATE personas SET {counter} = {counter} + 1, "
                    f"last_action_at = ? WHERE username = ?",
                    (now, username),
                )

    def bump_view_counter(self, username: str) -> None:
        """Increment total_views WITHOUT touching last_action_at.

        Used for the "passive view pass" that runs for every registered
        persona on every tick — scrolling and viewing feels like
        ordinary background browsing, NOT the deliberate 15-hour
        post/reply/like action. If we lumped it under `mark_action`,
        a persona who only ever viewed would never roll into the
        active-action eligibility window.
        """
        with self.transaction() as conn:
            conn.execute(
                "UPDATE personas SET total_views = total_views + 1 "
                "WHERE username = ?",
                (username,),
            )

    def all_personas(self) -> List[PersonaRow]:
        with self.transaction() as conn:
            rows = conn.execute(
                "SELECT username, user_id, password, registered_at, "
                "last_action_at, last_post_at, last_social_at, "
                "total_posts, total_replies, total_likes, total_views, "
                "graph_bootstrapped "
                "FROM personas"
            ).fetchall()
        return [PersonaRow(*r) for r in rows]

    # ── Graph-bootstrap marker ────────────────────────────────────

    def mark_graph_bootstrapped(self, username: str) -> None:
        """Flip the one-time seed flag so we never re-bootstrap the same
        persona twice (which would duplicate follow / friend-request
        attempts each tick)."""
        with self.transaction() as conn:
            conn.execute(
                "UPDATE personas SET graph_bootstrapped = 1 WHERE username = ?",
                (username,),
            )

    # ── Seen-post tracking ────────────────────────────────────────

    def record_seen(self, username: str, post_id: str, action: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO seen_posts (username, post_id, action, at) "
                "VALUES (?, ?, ?, ?)",
                (username, post_id, action, int(time.time())),
            )

    def has_acted_on(self, username: str, post_id: str, action: str) -> bool:
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT 1 FROM seen_posts "
                "WHERE username = ? AND post_id = ? AND action = ?",
                (username, post_id, action),
            ).fetchone()
        return row is not None

    # ── Cycle log ─────────────────────────────────────────────────

    def log(self, username: str, action: str, target: Optional[str] = None,
            detail: Optional[str] = None) -> None:
        with self.transaction() as conn:
            conn.execute(
                "INSERT INTO cycle_log (at, username, action, target, detail) "
                "VALUES (?, ?, ?, ?, ?)",
                (int(time.time()), username, action, target, detail),
            )
            # Bound the table at ~10k rows; old rows roll off.
            conn.execute(
                "DELETE FROM cycle_log WHERE id IN ("
                "  SELECT id FROM cycle_log ORDER BY id DESC LIMIT -1 OFFSET 10000"
                ")"
            )

    def recent_log(self, limit: int = 50) -> List[tuple]:
        with self.transaction() as conn:
            return conn.execute(
                "SELECT datetime(at, 'unixepoch'), username, action, target, detail "
                "FROM cycle_log ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
