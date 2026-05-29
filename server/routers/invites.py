"""
Invites Router — Referral program ("invite a friend, both get 1 month Raven+")

Endpoints:
- GET  /api/invites/code     → returns the caller's deterministic invite code + share URL
- POST /api/invites/redeem   → records a redemption + grants 30 days of premium to BOTH parties

Design notes
------------
The code is deterministic per user:  base32(SHA256(user_id || INVITE_SALT))[:8]
That means we don't need a row to mint codes — they're pure functions of the user
ID. Storage is only used to track redemptions + prevent abuse.

Anti-abuse guards in `redeem`:
  * device_fingerprint dedup (one redemption per device, ever)
  * inviter ≠ redeemer (you can't redeem your own code)
  * redeemer can only redeem ONE invite, ever
  * code must resolve to a real user
  * inviter and redeemer must be distinct
"""

import os
import hashlib
import base64
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, DateTime, Index
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/invites", tags=["invites"])


# ────────────────────────────────────────────────────────────────────────────
# Storage model — added to models on the fly via run_migrations() in main.py
# ────────────────────────────────────────────────────────────────────────────

class InviteRedemption(Base):
    """Records a single use of an invite code. Used for abuse prevention
    (one redemption per device, one per redeemer) and analytics."""
    __tablename__ = "invite_redemptions"

    id = Column(String, primary_key=True)
    inviter_id = Column(String, nullable=False, index=True)
    redeemer_id = Column(String, nullable=False, index=True)
    code = Column(String, nullable=False)
    device_fingerprint = Column(String, nullable=True, index=True)
    redeemed_at = Column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        Index("idx_invite_redemptions_inviter_redeemer", "inviter_id", "redeemer_id", unique=True),
    )


# ────────────────────────────────────────────────────────────────────────────
# Code derivation
# ────────────────────────────────────────────────────────────────────────────

def _invite_salt() -> str:
    """Pulled from env so leaking the source code doesn't leak the codes."""
    return os.environ.get("INVITE_SALT", "raven-invite-v1")


def _code_for_user(user_id: str) -> str:
    """Deterministic 8-char base32 code derived from user_id."""
    digest = hashlib.sha256(f"{user_id}|{_invite_salt()}".encode("utf-8")).digest()
    return base64.b32encode(digest)[:8].decode("ascii").upper()


def _user_for_code(db: Session, code: str) -> Optional[User]:
    """Reverse lookup: scan users for one whose derived code matches."""
    code = code.strip().upper()
    if len(code) != 8:
        return None
    # NOTE: this is O(N). For small/medium user bases it's fine. For scale,
    # add a `users.invite_code` indexed column populated lazily.
    for user in db.query(User).all():
        if _code_for_user(user.id) == code:
            return user
    return None


# ────────────────────────────────────────────────────────────────────────────
# Premium grant — server flips the flag now; on the client we already
# OR-merge SubscriptionService.serverGrantedPremium into PremiumLimits.isPremium.
# A separate worker can later call RevenueCat's promotional-entitlement API
# to also flip it on the RevenueCat side; UI will already reflect entitlement.
# ────────────────────────────────────────────────────────────────────────────

PREMIUM_GRANT_DAYS = 30


def _grant_premium(user: User, days: int = PREMIUM_GRANT_DAYS) -> None:
    """Mark a user as premium. If `premium_until` exists, extend it; else
    just flip `is_premium = True`."""
    user.is_premium = True
    if hasattr(user, "premium_until"):
        now = datetime.utcnow()
        existing = getattr(user, "premium_until", None)
        base = existing if existing and existing > now else now
        setattr(user, "premium_until", base + timedelta(days=days))


# ────────────────────────────────────────────────────────────────────────────
# Schemas
# ────────────────────────────────────────────────────────────────────────────

class InviteCodeResponse(BaseModel):
    code: str
    shareUrl: str = Field(..., alias="shareUrl")
    redeemedCount: int = Field(..., alias="redeemedCount")

    class Config:
        populate_by_name = True


class RedeemRequest(BaseModel):
    code: str
    deviceFingerprint: Optional[str] = None


class RedeemResponse(BaseModel):
    success: bool
    inviterId: Optional[str] = None
    grantedDays: int = PREMIUM_GRANT_DAYS
    message: Optional[str] = None


# ────────────────────────────────────────────────────────────────────────────
# Endpoints
# ────────────────────────────────────────────────────────────────────────────

@router.get("/code", response_model=InviteCodeResponse)
def get_my_invite_code(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return the caller's invite code + share URL + redemption count."""
    code = _code_for_user(current_user.id)
    redeemed = (
        db.query(InviteRedemption)
        .filter(InviteRedemption.inviter_id == current_user.id)
        .count()
    )
    share_url = f"https://raven.app/invite/{code}"
    return InviteCodeResponse(
        code=code,
        shareUrl=share_url,
        redeemedCount=redeemed,
    )


@router.post("/redeem", response_model=RedeemResponse)
def redeem_invite(
    body: RedeemRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """A new user redeems an invite code. Both sides receive 30 days of Raven+."""
    inviter = _user_for_code(db, body.code)
    if inviter is None:
        raise HTTPException(status_code=400, detail="Invalid invite code")
    if inviter.id == current_user.id:
        raise HTTPException(status_code=400, detail="You can't redeem your own code")

    # One redemption per redeemer, ever.
    already_used = (
        db.query(InviteRedemption)
        .filter(InviteRedemption.redeemer_id == current_user.id)
        .first()
    )
    if already_used is not None:
        raise HTTPException(status_code=400, detail="This account has already redeemed an invite")

    # One redemption per device, ever.
    if body.deviceFingerprint:
        device_used = (
            db.query(InviteRedemption)
            .filter(InviteRedemption.device_fingerprint == body.deviceFingerprint)
            .first()
        )
        if device_used is not None:
            raise HTTPException(status_code=400, detail="This device has already redeemed an invite")

    # Persist + grant
    import uuid
    redemption = InviteRedemption(
        id=str(uuid.uuid4()),
        inviter_id=inviter.id,
        redeemer_id=current_user.id,
        code=body.code.upper(),
        device_fingerprint=body.deviceFingerprint,
        redeemed_at=datetime.utcnow(),
    )
    db.add(redemption)

    _grant_premium(inviter)
    _grant_premium(current_user)

    db.commit()

    return RedeemResponse(
        success=True,
        inviterId=inviter.id,
        grantedDays=PREMIUM_GRANT_DAYS,
        message=f"You and your inviter both got {PREMIUM_GRANT_DAYS} days of Raven+",
    )
