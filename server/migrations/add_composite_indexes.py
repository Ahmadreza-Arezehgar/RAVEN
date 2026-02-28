"""
Add composite indexes for high-frequency query patterns.

These indexes target the exact WHERE + ORDER BY patterns used by feed,
message, and notification endpoints to avoid full table scans.

Run:  python migrations/add_composite_indexes.py
Safe: CREATE INDEX IF NOT EXISTS — idempotent, can be re-run safely.
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import engine, ENVIRONMENT
from sqlalchemy import text

INDEXES = [
    # ── Messages ──────────────────────────────────────────────
    # Unread message query: WHERE recipient_id = ? ORDER BY timestamp
    ("ix_messages_recipient_ts",       "messages",       "(recipient_id, timestamp DESC)"),
    # Conversation history: WHERE (sender, recipient) ORDER BY timestamp
    ("ix_messages_conversation",       "messages",       "(sender_id, recipient_id, timestamp DESC)"),

    # ── Posts / Feed ──────────────────────────────────────────
    # Global feed: WHERE visibility='public' AND is_hidden != true ORDER BY timestamp DESC
    ("ix_posts_feed_global",           "posts",          "(visibility, is_hidden, timestamp DESC)"),
    # Local feed: WHERE geohash LIKE ? AND visibility AND is_hidden ORDER BY timestamp DESC
    ("ix_posts_feed_local",            "posts",          "(geohash, visibility, is_hidden, timestamp DESC)"),
    # User posts: WHERE author_id = ? AND is_hidden != true ORDER BY timestamp DESC
    ("ix_posts_user_timeline",         "posts",          "(author_id, is_hidden, timestamp DESC)"),

    # ── Group Messages ────────────────────────────────────────
    # Group history: WHERE group_id = ? ORDER BY timestamp DESC
    ("ix_group_messages_group_ts",     "group_messages", "(group_id, timestamp DESC)"),

    # ── Notifications ─────────────────────────────────────────
    # Unread notifications: WHERE user_id = ? AND is_read = false ORDER BY timestamp DESC
    ("ix_notifications_user_unread",   "notifications",  "(user_id, is_read, timestamp DESC)"),

    # ── Friend Requests ───────────────────────────────────────
    # Friends lookup: WHERE requester_id = ? AND status = 'accepted'
    ("ix_friend_req_requester_status", "friend_requests", "(requester_id, status)"),
    ("ix_friend_req_recipient_status", "friend_requests", "(recipient_id, status)"),
]


def run():
    print(f"📊 Adding composite indexes ({ENVIRONMENT} environment)...")

    is_sqlite = "sqlite" in str(engine.url)

    with engine.connect() as conn:
        for name, table, columns in INDEXES:
            if is_sqlite:
                # SQLite doesn't support DESC in index, strip it
                cols_clean = columns.replace(" DESC", "")
                stmt = f"CREATE INDEX IF NOT EXISTS {name} ON {table} {cols_clean}"
            else:
                # PostgreSQL — use CONCURRENTLY for zero-downtime
                # (CONCURRENTLY cannot run inside a transaction block)
                stmt = f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {name} ON {table} {columns}"

            try:
                if not is_sqlite and "CONCURRENTLY" in stmt:
                    # PostgreSQL CONCURRENTLY requires autocommit
                    conn.execution_options(isolation_level="AUTOCOMMIT")
                conn.execute(text(stmt))
                print(f"  ✅ {name} on {table}")
            except Exception as e:
                print(f"  ⚠️ {name}: {e}")

    print("📊 Done.")


if __name__ == "__main__":
    run()
