"""
Linked Devices — multi-device session registry.

Each successful authenticated request can refresh a per-device "session" row
so the user can see every device they're signed in on and revoke any of
them ("Linked Devices" in Settings).

This is the v1 of multi-device. Full Signal-style cross-device key sync is
left for v2 (it's the hard part — server-mediated sender keys, end-to-end
across devices). v1 ships:

  * Server registry of (user_id, device_name, last_seen)
  * GET /api/linked-devices              → list user's devices
  * POST /api/linked-devices/heartbeat   → caller's device pings (idempotent upsert)
  * POST /api/linked-devices/{id}/revoke → kill switch

Heartbeat is called from the iOS app on cold start; the row is keyed on
`(user_id, device_name)` so the same physical device updates `last_seen_at`
instead of inserting duplicates.
"""

import uuid
from datetime import datetime
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Header, Request
from pydantic import BaseModel
from sqlalchemy import Column, String, DateTime
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/linked-devices", tags=["linked_devices"])


class LinkedDevice(Base):
    __tablename__ = "linked_devices"
    id = Column(String, primary_key=True)
    user_id = Column(String, nullable=False, index=True)
    device_name = Column(String, nullable=True)
    device_model = Column(String, nullable=True)
    device_os = Column(String, nullable=True)
    ip_first = Column(String, nullable=True)
    paired_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    last_seen_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    revoked_at = Column(DateTime, nullable=True)


# ────────────────────────────────────────────────────────────────────────
# Schemas
# ────────────────────────────────────────────────────────────────────────

class LinkedDeviceResponse(BaseModel):
    id: str
    deviceName: Optional[str]
    deviceModel: Optional[str]
    deviceOs: Optional[str]
    pairedAt: datetime
    lastSeenAt: datetime
    isThisDevice: bool


class HeartbeatRequest(BaseModel):
    deviceName: Optional[str] = None
    deviceModel: Optional[str] = None  # e.g. "iPhone 17 Pro"
    deviceOs: Optional[str] = None     # e.g. "iOS 26.4"


class HeartbeatResponse(BaseModel):
    deviceId: str


# ────────────────────────────────────────────────────────────────────────
# Endpoints
# ────────────────────────────────────────────────────────────────────────

@router.post("/heartbeat", response_model=HeartbeatResponse)
def heartbeat(
    body: HeartbeatRequest,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Idempotent register/refresh for the caller's device. Returns the
    device's stable id (clients can store this to know which row in the
    Linked Devices list represents them)."""
    name = (body.deviceName or "").strip()
    if not name:
        # Best-effort fallback — anything is better than blank.
        name = body.deviceModel or "Unknown device"

    existing = db.query(LinkedDevice).filter(
        LinkedDevice.user_id == current_user.id,
        LinkedDevice.device_name == name,
        LinkedDevice.revoked_at.is_(None),
    ).first()

    if existing is not None:
        existing.last_seen_at = datetime.utcnow()
        if body.deviceModel:
            existing.device_model = body.deviceModel
        if body.deviceOs:
            existing.device_os = body.deviceOs
        db.commit()
        return HeartbeatResponse(deviceId=existing.id)

    ip = request.client.host if request.client else None
    row = LinkedDevice(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        device_name=name,
        device_model=body.deviceModel,
        device_os=body.deviceOs,
        ip_first=ip,
    )
    db.add(row)
    db.commit()
    return HeartbeatResponse(deviceId=row.id)


@router.get("", response_model=List[LinkedDeviceResponse])
def list_devices(
    x_device_id: Optional[str] = Header(default=None, alias="X-Device-Id"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """List all (non-revoked) devices the user is signed in on."""
    rows = (
        db.query(LinkedDevice)
        .filter(
            LinkedDevice.user_id == current_user.id,
            LinkedDevice.revoked_at.is_(None),
        )
        .order_by(LinkedDevice.last_seen_at.desc())
        .all()
    )
    return [
        LinkedDeviceResponse(
            id=r.id,
            deviceName=r.device_name,
            deviceModel=r.device_model,
            deviceOs=r.device_os,
            pairedAt=r.paired_at,
            lastSeenAt=r.last_seen_at,
            isThisDevice=(r.id == x_device_id),
        )
        for r in rows
    ]


@router.post("/{device_id}/revoke")
def revoke_device(
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Revoke a linked device AND every refresh token bound to it.

    🔴 hacker-audit 2026-05-19 — token-revocation pipeline wired up.

    PREVIOUSLY this endpoint only set `LinkedDevice.revoked_at`. The
    docstring even acknowledged: "there's a separate token-revocation
    pipeline for true forced sign-out; the row simply hides it from
    the list." That separate pipeline was never called, so:

      • Stolen device → user opens Settings → "Revoke" → server
        marks the row revoked → attacker's iPhone keeps working
        because nobody invalidated its refresh token. Next /auth/
        refresh issues a new access token; user is none the wiser.
      • The "Revoke" button gave a false sense of safety. The only
        thing that actually stops the attacker is the natural 90-day
        refresh-token expiry — useless for an active compromise.

    FIX: when a device is revoked, also set `revoked_at` on every
    RefreshToken row whose `device_id` matches. Next /auth/refresh
    from the attacker's device errors out and the session is dead.
    Access tokens already issued live until their short TTL (15 min
    by default) — acceptable; the bleed-window is bounded.
    """
    row = db.query(LinkedDevice).filter(
        LinkedDevice.id == device_id,
        LinkedDevice.user_id == current_user.id,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Device not found")
    if row.revoked_at is not None:
        return {"status": "already_revoked"}
    now = datetime.utcnow()
    row.revoked_at = now

    # Invalidate all refresh tokens bound to this device.
    from models import RefreshToken as _RT
    revoked_count = db.query(_RT).filter(
        _RT.user_id == current_user.id,
        _RT.device_id == device_id,
        _RT.revoked_at.is_(None),
    ).update({"revoked_at": now}, synchronize_session=False)

    # 🔴 ROUND 71 phase 3 — clear the user-level push token on
    # revoke. The `users.push_token` column is shared across all
    # the user's devices (FIFO: last device to register wins), so
    # a stolen iPhone whose token is still stored continues to
    # receive APNs message-preview pushes — leaking content even
    # after the user has "revoked" it from the Linked Devices
    # screen. Null the column so APNs delivery to the stolen device
    # stops immediately; any legitimate device the user keeps will
    # re-register its push token on the next foreground via
    # `/users/push-token`. This is a best-effort fix until push
    # tokens are moved to per-LinkedDevice rows.
    cleared_push = False
    if current_user.push_token:
        current_user.push_token = None
        current_user.push_platform = None
        cleared_push = True

    db.commit()
    print(f"🔌 [LinkedDevice] {current_user.username} revoked device {device_id[:8]} "
          f"(+{revoked_count} refresh tokens, push_cleared={cleared_push})")
    return {
        "status": "revoked",
        "refresh_tokens_revoked": revoked_count,
        "push_token_cleared": cleared_push,
    }
