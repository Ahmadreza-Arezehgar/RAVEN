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
import logging
from typing import Optional, Any

logger = logging.getLogger(__name__)

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")

# Default TTLs (seconds)
TTL_FEED = 30          # Feed lists: 30 seconds
TTL_PROFILE = 60       # User profiles: 1 minute
TTL_INTERESTS = 300    # User interests: 5 minutes


class RedisCache:
    """Thin Redis caching wrapper with graceful fallback."""

    def __init__(self):
        self._redis = None
        self._available = False

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
        """Get cached value. Returns None on miss or error."""
        self._connect()
        if not self._available:
            return None
        try:
            raw = self._redis.get(f"cache:{key}")
            if raw is None:
                return None
            logger.debug(f"🎯 [Cache] HIT {key}")
            return json.loads(raw)
        except Exception as e:
            logger.warning(f"⚠️ [Cache] GET error: {e}")
            return None

    def set(self, key: str, value: Any, ttl: int = TTL_FEED) -> None:
        """Cache a JSON-serialisable value with TTL in seconds."""
        self._connect()
        if not self._available:
            return
        try:
            self._redis.setex(f"cache:{key}", ttl, json.dumps(value, default=str))
            logger.debug(f"💾 [Cache] SET {key} (ttl={ttl}s)")
        except Exception as e:
            logger.warning(f"⚠️ [Cache] SET error: {e}")

    def invalidate(self, pattern: str) -> int:
        """Delete all keys matching glob pattern. Returns count deleted."""
        self._connect()
        if not self._available:
            return 0
        try:
            cursor = 0
            deleted = 0
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
            return 0

    @property
    def available(self) -> bool:
        """Check if Redis cache is available."""
        self._connect()
        return self._available


# Global singleton
cache = RedisCache()
