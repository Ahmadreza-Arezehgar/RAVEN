"""
E2EE Pre-Key Bundle Router.

Stores public X3DH pre-key bundles per (user_id, device_id) so that
initiators can fetch them and bootstrap a Double Ratchet session
asynchronously — even when the recipient is offline.

Storage model
─────────────
e2ee_bundles          one row per (user_id, device_id)  ← long-lived
e2ee_one_time_prekeys queue of unused OPKs              ← consumed once

Privacy model
─────────────
The server stores ONLY public material. It can hand out bundles to
anyone authenticated, but it cannot derive any session key or read
any subsequent message — that's the whole point of X3DH.

We log every OPK consumption with the requester id so abuse (one user
draining another user's pool) is detectable.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import Column, String, Integer, Float, ForeignKey, Boolean, Index
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import logging

from database import get_db, Base
from models import User
from routers.users import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/e2ee", tags=["e2ee"])


# ──────────────────────────────────────────────────────────────────────────
# DB models
# ──────────────────────────────────────────────────────────────────────────

class E2EEBundle(Base):
    """Long-lived part of a user's pre-key bundle."""
    __tablename__ = "e2ee_bundles"

    user_id = Column(String, ForeignKey("users.id"), primary_key=True)
    device_id = Column(String, primary_key=True)

    identity_key = Column(String, nullable=False)            # base64 Ed25519
    identity_agreement_key = Column(String, nullable=False)  # base64 X25519
    signed_pre_key_id = Column(Integer, nullable=False)
    signed_pre_key = Column(String, nullable=False)          # base64 X25519
    signed_pre_key_signature = Column(String, nullable=False)  # base64 Ed25519
    signed_pre_key_created_at = Column(Float, nullable=False)
    created_at = Column(Float, nullable=False)
    updated_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())


class E2EEOneTimePreKey(Base):
    """Single-use pre-keys. Consumed (i.e. handed out) at most once."""
    __tablename__ = "e2ee_one_time_prekeys"

    # Composite PK: (user_id, device_id, key_id) — caller-supplied id.
    user_id = Column(String, ForeignKey("users.id"), primary_key=True)
    device_id = Column(String, primary_key=True)
    key_id = Column(Integer, primary_key=True)

    public_key = Column(String, nullable=False)              # base64 X25519
    consumed = Column(Boolean, default=False, nullable=False)
    consumed_by = Column(String, nullable=True)              # user_id of fetcher
    consumed_at = Column(Float, nullable=True)
    created_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())


# Common lookup index — speeds up the unconsumed-OPK pop in fetch_bundle.
Index(
    "ix_e2ee_opk_pool",
    E2EEOneTimePreKey.user_id,
    E2EEOneTimePreKey.device_id,
    E2EEOneTimePreKey.consumed,
)


# ──────────────────────────────────────────────────────────────────────────
# Pydantic schemas
# ──────────────────────────────────────────────────────────────────────────

class OneTimePreKeyDTO(BaseModel):
    id: int
    public_key: str


class UploadBundleRequest(BaseModel):
    user_id: str
    device_id: str
    identity_key: str
    identity_agreement_key: str
    signed_pre_key_id: int
    signed_pre_key: str
    signed_pre_key_signature: str
    signed_pre_key_created_at: float
    one_time_pre_keys: List[OneTimePreKeyDTO]
    created_at: float


class UploadOneTimeBatch(BaseModel):
    user_id: str
    device_id: str
    one_time_pre_keys: List[OneTimePreKeyDTO]


class FetchedBundleResponse(BaseModel):
    user_id: str
    device_id: str
    identity_key: str
    identity_agreement_key: str
    signed_pre_key_id: int
    signed_pre_key: str
    signed_pre_key_signature: str
    signed_pre_key_created_at: float
    one_time_pre_key: Optional[OneTimePreKeyDTO] = None
    created_at: float


class CountResponse(BaseModel):
    count: int


# ──────────────────────────────────────────────────────────────────────────
# Validation helpers
# ──────────────────────────────────────────────────────────────────────────

def _ensure_bundle_owner(current_user: User, user_id: str) -> None:
    """A user may only publish bundles under their own user_id."""
    if str(current_user.id) != str(user_id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot publish bundle on behalf of another user.",
        )


# ──────────────────────────────────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────────────────────────────────

@router.post("/bundle", status_code=status.HTTP_204_NO_CONTENT)
def upload_bundle(
    body: UploadBundleRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Publish (or replace) the bundle for one of our devices."""
    _ensure_bundle_owner(current_user, body.user_id)

    existing = db.query(E2EEBundle).filter_by(
        user_id=body.user_id, device_id=body.device_id
    ).first()

    now = datetime.utcnow().timestamp()
    if existing:
        existing.identity_key = body.identity_key
        existing.identity_agreement_key = body.identity_agreement_key
        existing.signed_pre_key_id = body.signed_pre_key_id
        existing.signed_pre_key = body.signed_pre_key
        existing.signed_pre_key_signature = body.signed_pre_key_signature
        existing.signed_pre_key_created_at = body.signed_pre_key_created_at
        existing.updated_at = now
    else:
        db.add(E2EEBundle(
            user_id=body.user_id,
            device_id=body.device_id,
            identity_key=body.identity_key,
            identity_agreement_key=body.identity_agreement_key,
            signed_pre_key_id=body.signed_pre_key_id,
            signed_pre_key=body.signed_pre_key,
            signed_pre_key_signature=body.signed_pre_key_signature,
            signed_pre_key_created_at=body.signed_pre_key_created_at,
            created_at=body.created_at,
            updated_at=now,
        ))

    # Replace the one-time pool with whatever the client sent. Old
    # unconsumed OPKs are deleted — the client is the source of truth.
    db.query(E2EEOneTimePreKey).filter_by(
        user_id=body.user_id, device_id=body.device_id
    ).delete()
    for opk in body.one_time_pre_keys:
        db.add(E2EEOneTimePreKey(
            user_id=body.user_id,
            device_id=body.device_id,
            key_id=opk.id,
            public_key=opk.public_key,
            consumed=False,
            created_at=now,
        ))

    db.commit()
    logger.info(
        "[e2ee] Bundle uploaded for %s/%s with %d one-time pre-keys",
        body.user_id, body.device_id, len(body.one_time_pre_keys),
    )
    return None


@router.post("/onetime", status_code=status.HTTP_204_NO_CONTENT)
def upload_one_time_batch(
    body: UploadOneTimeBatch,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Top up the one-time pre-key pool without rotating the bundle."""
    _ensure_bundle_owner(current_user, body.user_id)

    now = datetime.utcnow().timestamp()
    for opk in body.one_time_pre_keys:
        # Conflict on (user_id, device_id, key_id) means a duplicate
        # id — caller bug. Reject the batch rather than overwrite.
        existing = db.query(E2EEOneTimePreKey).filter_by(
            user_id=body.user_id, device_id=body.device_id, key_id=opk.id
        ).first()
        if existing:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"one-time pre-key id {opk.id} already exists",
            )
        db.add(E2EEOneTimePreKey(
            user_id=body.user_id,
            device_id=body.device_id,
            key_id=opk.id,
            public_key=opk.public_key,
            consumed=False,
            created_at=now,
        ))
    db.commit()
    logger.info(
        "[e2ee] %d one-time pre-keys added for %s/%s",
        len(body.one_time_pre_keys), body.user_id, body.device_id,
    )
    return None


@router.get("/bundle/{user_id}/{device_id}", response_model=FetchedBundleResponse)
def fetch_bundle(
    user_id: str,
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Hand out one bundle. Pops one OPK off the queue if available.

    🔴 ROUND 48 (2026-05-19) — hacker-audit Server F12 (HIGH:
    forward-secrecy degradation via OPK exhaustion).

    PREVIOUSLY: every authenticated user could call this endpoint
    against ANY (target_user_id, device_id) pair and consume a
    one-time pre-key. The endpoint had no rate-limit, no relationship
    check, and the docstring openly admitted "We log every OPK
    consumption … so abuse … is detectable" — detection, not
    prevention. Concrete attack:

      • Attacker writes a 10-line shell loop that requests the bundle
        100× in 2 s for a target user_id (UUIDs are visible in posts,
        group rosters, friend graphs).
      • All 100 OPKs are now `consumed=True`. The next legitimate
        initiator gets `one_time_pre_key=None` and X3DH degrades to
        signed-pre-key-only — same long-lived ephemeral reused across
        every subsequent first-contact, weakening forward secrecy of
        that initial round and inviting key-compromise replay if the
        signed pre-key is ever exposed.
      • Attacker's only cost: a valid access token (any account).

    FIX (defense in depth):
      1. Cap how many OPKs a single FETCHER can consume from a single
         TARGET in a rolling 1-hour window. Beyond the cap, return
         the bundle with `one_time_pre_key=None` (forces the caller
         to fall back to signed-pre-key, same as if the pool was
         legitimately empty). Existing per-fetcher consumption is
         visible via the `consumed_by` column, so the cap is queryable
         without a new table.
      2. Reject self-fetches that consume from your own pool — those
         are pointless and the only legitimate reason is a re-key
         flow (which uses `/bundle` upload, not `/bundle` fetch).
    """
    # 🔴 ROUND 48 — self-fetch with OPK consumption is never
    # legitimate (the owner already holds the private half).
    # Allow reading the public bundle so multi-device sees own keys,
    # but skip the OPK pop.
    is_self_fetch = (str(current_user.id) == str(user_id))

    bundle = db.query(E2EEBundle).filter_by(
        user_id=user_id, device_id=device_id
    ).first()
    if not bundle:
        raise HTTPException(status_code=404, detail="bundle not found")

    one_time = None

    if not is_self_fetch:
        # 🔴 ROUND 48 — per-(fetcher, target) hourly OPK cap.
        # 3 OPKs per fetcher per target per hour is enough for the
        # legitimate cases: a fresh first contact + a second device
        # bootstrap + one re-key. Beyond that, an honest client
        # caches the result and doesn't refetch.
        from sqlalchemy import and_
        one_hour_ago = datetime.utcnow().timestamp() - 3600.0
        recent_consumed = (
            db.query(E2EEOneTimePreKey)
            .filter(
                E2EEOneTimePreKey.user_id == user_id,
                E2EEOneTimePreKey.device_id == device_id,
                E2EEOneTimePreKey.consumed_by == str(current_user.id),
                E2EEOneTimePreKey.consumed_at != None,  # noqa: E711
                E2EEOneTimePreKey.consumed_at > one_hour_ago,
            )
            .count()
        )

        if recent_consumed >= 3:
            # Cap hit — log loudly and fall through with no OPK.
            # The bundle is still served so the conversation can
            # start; X3DH gracefully degrades to no-OPK mode.
            logger.warning(
                "[e2ee] OPK cap hit: fetcher=%s target=%s/%s recent=%d — serving bundle without OPK",
                current_user.id, user_id, device_id, recent_consumed,
            )
        else:
            # Atomically grab the next unconsumed OPK. We update first,
            # then read — UPDATE … RETURNING isn't portable across
            # SQLite/Postgres so we do it in two steps inside one
            # transaction.
            opk_row = (
                db.query(E2EEOneTimePreKey)
                .filter_by(user_id=user_id, device_id=device_id, consumed=False)
                .order_by(E2EEOneTimePreKey.key_id.asc())
                .with_for_update(skip_locked=True)  # Postgres-friendly; ignored on sqlite
                .first()
            )
            if opk_row:
                opk_row.consumed = True
                opk_row.consumed_by = str(current_user.id)
                opk_row.consumed_at = datetime.utcnow().timestamp()
                db.flush()
                one_time = OneTimePreKeyDTO(id=opk_row.key_id, public_key=opk_row.public_key)

    db.commit()

    return FetchedBundleResponse(
        user_id=bundle.user_id,
        device_id=bundle.device_id,
        identity_key=bundle.identity_key,
        identity_agreement_key=bundle.identity_agreement_key,
        signed_pre_key_id=bundle.signed_pre_key_id,
        signed_pre_key=bundle.signed_pre_key,
        signed_pre_key_signature=bundle.signed_pre_key_signature,
        signed_pre_key_created_at=bundle.signed_pre_key_created_at,
        one_time_pre_key=one_time,
        created_at=bundle.created_at,
    )


@router.get("/onetime_count", response_model=CountResponse)
def remaining_one_time_count(
    user_id: str,
    device_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """How many unused OPKs remain. Owner-only — leaks no info to others."""
    _ensure_bundle_owner(current_user, user_id)
    count = (
        db.query(E2EEOneTimePreKey)
        .filter_by(user_id=user_id, device_id=device_id, consumed=False)
        .count()
    )
    return CountResponse(count=count)
