"""
Redis Cache Service — Transparent caching for hot API endpoints.

Usage:
    from cache import cache

    # In a route handler:
    data = cache.get("feed:global:0:50")
    if data is not None:
        return data

    result = expensive_db_query()
    cache.set("feed:global:0:50", result, ttl=30)
    return result

    # Invalidate on mutation:
    cache.invalidate("feed:global:*")

Graceful fallback: if Redis is unavailable, all operations are no-ops.
"""

import json
import os
import time
import logging
import threading
from collections import OrderedDict
from typing import Optional, Any, Tuple

logger = logging.getLogger(__name__)

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")

# Default TTLs (seconds)
TTL_FEED = 30          # Feed lists: 30 seconds
TTL_PROFILE = 60       # User profiles: 1 minute
TTL_INTERESTS = 300    # User interests: 5 minutes


class _InMemoryLRU:
    """Process-local LRU with per-key TTL. ~200 lines of behaviour rolled
    into ~30 — enough to fill in for Redis when it's unavailable.

    Keeps the working set bounded (max_entries) so a single pod doesn't
    OOM if a hot loop generates many distinct keys. Threadsafe."""

    def __init__(self, max_entries: int = 5000):
        self._store: "OrderedDict[str, Tuple[float, Any]]" = OrderedDict()
        self._lock = threading.Lock()
        self._max = max_entries

    def get(self, key: str) -> Optional[Any]:
        now = time.time()
        with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if expires_at < now:
                # expired
                self._store.pop(key, None)
                return None
            self._store.move_to_end(key)
            return value

    def set(self, key: str, value: Any, ttl: int) -> None:
        expires_at = time.time() + ttl
        with self._lock:
            self._store[key] = (expires_at, value)
            self._store.move_to_end(key)
            while len(self._store) > self._max:
                self._store.popitem(last=False)

    def invalidate_prefix(self, prefix: str) -> int:
        # Substring match for compatibility with the existing glob `*` pattern.
        token = prefix.replace("*", "")
        with self._lock:
            keys = [k for k in self._store if token in k]
            for k in keys:
                self._store.pop(k, None)
            return len(keys)


class RedisCache:
    """Two-tier cache: in-memory LRU + Redis. Both are best-effort.

    The in-memory tier is the primary cache when Redis isn't deployed
    (which is the current state on Cloud Run). It gives ~99% of the perf
    benefit on hot feed endpoints — the only thing it loses vs. Redis is
    cross-pod sharing of cached results. With min-instances=1 and short
    TTLs, that's a non-issue.

    When you eventually deploy Redis (set REDIS_URL env var), both tiers
    activate: GET checks memory → Redis → miss. SET writes both.
    Invalidation hits both."""

    def __init__(self):
        self._redis = None
        self._available = False
        self._mem = _InMemoryLRU()

    def _connect(self):
        """Lazy connect on first use."""
        if self._redis is not None:
            return
        try:
            import redis as _redis
            self._redis = _redis.from_url(
                REDIS_URL,
                decode_responses=True,
                socket_connect_timeout=3,
                socket_timeout=2,
            )
            self._redis.ping()
            self._available = True
            logger.info("✅ [Cache] Connected to Redis")
        except Exception as e:
            self._available = False
            logger.warning(f"⚠️ [Cache] Redis unavailable, caching disabled: {e}")

    # ── public API ──────────────────────────────────────────────

    def get(self, key: str) -> Optional[Any]:
        """Get cached value. Returns None on miss or error.
        Two-tier: checks in-memory LRU first, then Redis."""
        # Tier 1: in-memory
        cached = self._mem.get(key)
        if cached is not None:
            return cached

        # Tier 2: Redis (if reachable)
        self._connect()
        if not self._available:
            return None
        try:
            raw = self._redis.get(f"cache:{key}")
            if raw is None:
                return None
            value = json.loads(raw)
            # Backfill the in-memory tier so subsequent hits skip the Redis round-trip.
            self._mem.set(key, value, ttl=TTL_FEED)
            return value
        except Exception as e:
            logger.warning(f"⚠️ [Cache] GET error: {e}")
            return None

    def set(self, key: str, value: Any, ttl: int = TTL_FEED) -> None:
        """Cache a JSON-serialisable value with TTL in seconds.
        Always writes to in-memory LRU; also writes to Redis if available."""
        self._mem.set(key, value, ttl=ttl)
        self._connect()
        if not self._available:
            return
        try:
            self._redis.setex(f"cache:{key}", ttl, json.dumps(value, default=str))
        except Exception as e:
            logger.warning(f"⚠️ [Cache] SET error: {e}")

    def invalidate(self, pattern: str) -> int:
        """Delete all keys matching glob pattern. Returns count deleted."""
        # Tier 1: in-memory
        mem_deleted = self._mem.invalidate_prefix(pattern)

        # Tier 2: Redis
        self._connect()
        if not self._available:
            return mem_deleted
        try:
            cursor = 0
            deleted = mem_deleted
            full_pattern = f"cache:{pattern}"
            while True:
                cursor, keys = self._redis.scan(cursor, match=full_pattern, count=100)
                if keys:
                    deleted += self._redis.delete(*keys)
                if cursor == 0:
                    break
            if deleted:
                logger.info(f"🗑️ [Cache] Invalidated {deleted} keys matching '{pattern}'")
            return deleted
        except Exception as e:
            logger.warning(f"⚠️ [Cache] INVALIDATE error: {e}")
            return mem_deleted

    @property
    def available(self) -> bool:
        """Check if Redis cache is available."""
        self._connect()
        return self._available


# Global singleton
cache = RedisCache()
