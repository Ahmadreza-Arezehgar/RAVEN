"""
Presence Router - Track user online/offline status for hybrid messaging
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
from typing import Optional
from pydantic import BaseModel

from database import get_db
from models import User
from auth import get_current_user

router = APIRouter(prefix="/api/presence", tags=["Presence"])


# MARK: - Response Models

class PresenceResponse(BaseModel):
    """User presence status for routing decisions"""
    online: bool
    hasInternet: bool
    lastSeenAt: Optional[str] = None
    
    class Config:
        from_attributes = True


class PresenceUpdateRequest(BaseModel):
    """Client reports its own presence"""
    has_internet: bool = True
    device_id: Optional[str] = None


# MARK: - DB-backed presence
# Cloud Run runs multiple instances — an in-memory cache only works
# within a single instance, which broke cross-device presence (heartbeat
# hits instance A, query hits instance B → "offline"). Now we read/write
# users.last_active_at directly so presence survives instance scale-up
# and is consistent across the cluster.

ONLINE_THRESHOLD_SECONDS = 60  # Consider offline after 60s of no heartbeat


def _is_online(target_user: User) -> tuple[bool, bool, Optional[datetime]]:
    """Check if user is online based on last_active_at column.

    "Online" means: heartbeat received within the last 60s AND the client
    is currently reporting it has internet. The /offline endpoint flips
    last_active_has_internet=false so backgrounded apps reflect as
    offline immediately rather than waiting for the 60s threshold.
    """
    last_active = getattr(target_user, "last_active_at", None)
    if not last_active:
        return False, False, None

    now = datetime.utcnow()
    has_internet = bool(getattr(target_user, "last_active_has_internet", False))
    is_recent = (now - last_active).total_seconds() < ONLINE_THRESHOLD_SECONDS
    return (is_recent and has_internet), has_internet, last_active


# MARK: - Endpoints

@router.get("/{user_id}", response_model=PresenceResponse)
def get_presence(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get presence status of a user.
    Used by sender to decide routing: server-only vs server+mesh parallel.
    """
    # Verify target user exists
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    online, has_internet, last_seen = _is_online(target_user)

    # ✅ Privacy: hide online status if user disabled it
    if not getattr(target_user, 'show_online_status', True):
        return PresenceResponse(
            online=False,
            hasInternet=False,
            lastSeenAt=None
        )

    return PresenceResponse(
        online=online,
        hasInternet=has_internet,
        lastSeenAt=last_seen.isoformat() if last_seen else None
    )


@router.post("/heartbeat")
async def heartbeat(
    req: PresenceUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Client sends heartbeat to indicate it's online.
    Should be called every 30 seconds while app is active.
    Writes to DB so presence is consistent across Cloud Run instances.
    """
    now = datetime.utcnow()
    current_user.last_active_at = now
    current_user.last_active_has_internet = bool(req.has_internet)
    db.commit()

    return {"status": "ok", "timestamp": now.isoformat()}


@router.post("/offline")
def go_offline(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Client explicitly goes offline (app backgrounded, closed, etc.).
    We do NOT clear last_active_at — that's used for "last seen N min ago".
    Instead we set last_active_has_internet=False so reads return offline
    immediately (without waiting for the 60s heartbeat threshold).
    """
    current_user.last_active_has_internet = False
    db.commit()
    return {"status": "ok"}


@router.get("/debug/all")
def debug_all_presence(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Debug: return everyone's presence row (admin only — TODO add gate)."""
    rows = db.query(User).filter(User.last_active_at.isnot(None)).limit(50).all()
    result = {}
    for u in rows:
        online, has_internet, last_seen = _is_online(u)
        result[u.id[:8]] = {
            "online": online,
            "has_internet": has_internet,
            "last_seen": last_seen.isoformat() if last_seen else None,
        }
    return result
