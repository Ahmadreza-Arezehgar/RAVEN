"""
Stats Router - Public live statistics (no auth required)
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from sqlalchemy import func
from datetime import datetime, timedelta
import os
import httpx
import logging

from database import get_db
from models import User, Message, Post

router = APIRouter(prefix="/api/stats", tags=["stats"])
logger = logging.getLogger(__name__)

PROD_BASE = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
# 🔴 hacker-audit 2026-05-20 — no hardcoded admin-secret fallback.
# PREVIOUSLY this defaulted to the in-source literal "RAVEN_ADMIN_2026";
# anyone who read the repo could authenticate to every
# X-Admin-Secret-gated admin endpoint. It now comes only from the
# environment — unset means the cross-server admin call is skipped.
ADMIN_SECRET = os.getenv("ADMIN_SECRET")
IS_DEV = os.getenv("ENV", "development") == "development"


async def _get_production_stats():
    """Fetch user count from production via admin API (server-side, no CORS)."""
    # 🔴 hacker-audit 2026-05-20 — ADMIN_SECRET no longer has a
    # hardcoded fallback; if it isn't configured, skip the
    # cross-server admin call rather than sending a bogus header.
    if not ADMIN_SECRET:
        return None
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # Get users with push tokens (gives us a list of active users)
            r = await client.get(
                f"{PROD_BASE}/api/admin/push-debug",
                headers={"X-Admin-Secret": ADMIN_SECRET}
            )
            if r.status_code != 200:
                return None

            data = r.json()
            token_users = data.get("users_with_tokens", [])

            # Now count ALL users via check-username brute force? No.
            # Better: use the auth/check-username endpoint to count known users.
            # Actually we already know the token users. For total count, we need 
            # a different approach.
            
            # Get total user count by querying a search with empty-ish query
            # Actually, let's use a smarter approach - query the production stats
            # endpoint itself (once deployed), and fall back to push-debug count
            try:
                stats_r = await client.get(f"{PROD_BASE}/api/stats/live", timeout=5)
                if stats_r.status_code == 200:
                    return stats_r.json()
            except Exception:
                pass

            # Fallback: estimate from push-debug data
            return {
                "total_users": len(token_users),
                "online_users": 0,
                "total_messages": 0,
                "total_posts": 0,
                "new_users_today": 0,
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "source": "production (estimated from push-debug)"
            }
    except Exception as e:
        logger.warning(f"Failed to fetch production stats: {e}")
        return None


@router.get("/live")
async def get_live_stats(db: Session = Depends(get_db)):
    """
    Public endpoint: returns live platform statistics.
    No authentication required — designed for the live dashboard.
    
    In dev mode: proxies data from production server.
    In production: reads directly from the database.
    """
    # In dev mode, try to get production data first
    if IS_DEV:
        prod_stats = await _get_production_stats()
        if prod_stats:
            return prod_stats

    now = datetime.utcnow()

    # 1. Total registered accounts in DB
    total_users = db.query(func.count(User.id)).scalar() or 0

    # 2. Currently online users (from in-memory presence cache)
    from routers.presence import _presence_cache, ONLINE_THRESHOLD_SECONDS
    online_users = 0
    for entry in _presence_cache.values():
        last_seen = entry.get("last_seen")
        if last_seen and (now - last_seen).total_seconds() < ONLINE_THRESHOLD_SECONDS:
            online_users += 1

    # 3. Total messages sent
    total_messages = db.query(func.count(Message.id)).scalar() or 0

    # 4. Total posts created
    total_posts = db.query(func.count(Post.id)).scalar() or 0

    # 5. New accounts registered today (last 24h)
    since_24h = now - timedelta(hours=24)
    new_users_today = db.query(func.count(User.id)).filter(
        User.created_at >= since_24h
    ).scalar() or 0

    return {
        "total_users": total_users,
        "online_users": online_users,
        "total_messages": total_messages,
        "total_posts": total_posts,
        "new_users_today": new_users_today,
        "timestamp": now.isoformat() + "Z",
    }
