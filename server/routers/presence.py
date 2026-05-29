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


# MARK: - In-Memory Presence Cache (for MVP)
# TODO: Replace with Redis for production

_presence_cache: dict[str, dict] = {}
ONLINE_THRESHOLD_SECONDS = 60  # Consider offline after 60s of no heartbeat


def _is_online(user_id: str) -> tuple[bool, bool, Optional[datetime]]:
    """Check if user is online based on recent heartbeat"""
    if user_id not in _presence_cache:
        return False, False, None
    
    entry = _presence_cache[user_id]
    last_seen = entry.get("last_seen")
    
    if not last_seen:
        return False, False, None
    
    # Check if heartbeat is recent enough
    now = datetime.utcnow()
    is_online = (now - last_seen).total_seconds() < ONLINE_THRESHOLD_SECONDS
    has_internet = entry.get("has_internet", False) if is_online else False
    
    return is_online, has_internet, last_seen


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
    
    online, has_internet, last_seen = _is_online(user_id)
    
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
    current_user: User = Depends(get_current_user)
):
    """
    Client sends heartbeat to indicate it's online.
    Should be called every 30 seconds while app is active.
    
    ⚡ Optimized: Uses in-memory cache only, no DB queries.
    """
    user_id = str(current_user.id)
    
    _presence_cache[user_id] = {
        "last_seen": datetime.utcnow(),
        "has_internet": req.has_internet,
        "device_id": req.device_id
    }
    
    print(f"💓 [Presence] Heartbeat from {user_id[:8]}, hasInternet={req.has_internet}")
    
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}


@router.post("/offline")
def go_offline(current_user: User = Depends(get_current_user)):
    """
    Client explicitly goes offline (app backgrounded, closed, etc.)
    """
    user_id = str(current_user.id)
    
    if user_id in _presence_cache:
        _presence_cache[user_id]["has_internet"] = False
        # Keep last_seen for "last seen X minutes ago"
    
    print(f"👋 [Presence] User {user_id[:8]} went offline")
    
    return {"status": "ok"}


@router.get("/debug/all", include_in_schema=False)
def debug_all_presence(_admin: bool = Depends(__import__("routers.admin", fromlist=["verify_admin_secret"]).verify_admin_secret)):
    """Debug endpoint to see all presence data — admin only.

    🔴 hacker-audit 2026-05-19: docstring claimed "admin only" but the
    code had a literal `# TODO: Add admin check`. Any authenticated
    user could dump the in-process presence cache and:
      • Build a per-user activity-time graph (which targets are
        online when), correlating with messages they receive.
      • Trace failed-login attempts to specific accounts via the
        device_id field.
      • Enumerate active accounts on the server (any user with
        a recent heartbeat appears).
    Now gated on X-Admin-Secret, same gate as every other admin op.
    """
    result = {}
    for user_id, data in _presence_cache.items():
        online, has_internet, last_seen = _is_online(user_id)
        result[user_id[:8]] = {
            "online": online,
            "has_internet": has_internet,
            "last_seen": last_seen.isoformat() if last_seen else None
        }
    return result
