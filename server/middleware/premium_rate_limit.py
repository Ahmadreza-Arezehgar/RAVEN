"""
Premium Rate Limiter — AI & Transcribe Daily Quota

Free users: 3 AI/transcribe calls per day
Premium users: Unlimited

Returns 402 Payment Required when quota exhausted — iOS auto-shows paywall on 402.

Uses in-memory dict (suitable for single Cloud Run instance).
For multi-instance scaling, swap to Redis.
"""

from fastapi import HTTPException, status
from datetime import date
from models import User
import logging

logger = logging.getLogger(__name__)

# In-memory quota tracker: { user_id: { "date": "2026-02-16", "count": 3 } }
_ai_quota: dict = {}

# Limits
FREE_DAILY_QUOTA = 3
PREMIUM_DAILY_QUOTA = 999_999  # Effectively unlimited


def check_ai_quota(user: User) -> None:
    """
    Check if the user has remaining AI/transcribe quota for today.
    
    Raises:
        HTTPException 402 if free user has exhausted daily quota.
    """
    # Premium users have unlimited access
    if user.is_premium:
        return
    
    today = date.today().isoformat()
    user_quota = _ai_quota.get(user.id)
    
    if user_quota and user_quota["date"] == today:
        if user_quota["count"] >= FREE_DAILY_QUOTA:
            logger.info(f"🚫 [Quota] {user.username} exceeded AI daily limit ({FREE_DAILY_QUOTA}/day)")
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail={
                    "error": "ai_quota_exceeded",
                    "message": f"Free users are limited to {FREE_DAILY_QUOTA} AI requests per day. Upgrade to RAVEN+ for unlimited access.",
                    "limit": FREE_DAILY_QUOTA,
                    "used": user_quota["count"],
                    "resets_at": f"{today}T00:00:00Z"
                }
            )
        user_quota["count"] += 1
    else:
        # First call today or new day — reset
        _ai_quota[user.id] = {"date": today, "count": 1}
    
    remaining = FREE_DAILY_QUOTA - _ai_quota[user.id]["count"]
    logger.info(f"📊 [Quota] {user.username}: {_ai_quota[user.id]['count']}/{FREE_DAILY_QUOTA} AI calls today ({remaining} remaining)")
