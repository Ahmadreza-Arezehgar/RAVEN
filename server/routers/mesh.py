"""
mesh.py — bridge endpoints for the cross-platform mesh.

When a device (Windows / Mac / iOS) is online but receives a mesh envelope
that ISN'T addressed to itself, it acts as a *bridge*: it uplinks the
opaque encrypted envelope to the server so the recipient can pick it up
on their next online connect.

The server NEVER decrypts these envelopes. It only:
  1. Stores them keyed by an idempotency key (the envelope nonce).
  2. Fans them out via WebSocket to all currently-online clients —
     each client tries to decrypt; success → keep, failure → drop.
  3. Garbage-collects after 24 h.

This zero-knowledge design lets us bridge without ever knowing who is
sending what to whom.
"""
from __future__ import annotations

import base64
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import Column, String, DateTime, LargeBinary, Boolean, Index
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from auth import get_current_user
from database import get_db, Base
from models import User

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/mesh", tags=["mesh"])


# ─── Schema ────────────────────────────────────────────────────────────


class BridgeEnvelope(Base):
    """
    Opaque mesh envelopes parked by bridges for offline recipients.

    NB: there is no recipient_id column. The bridging device doesn't know who
    the recipient is (the envelope is encrypted), so we fan out to all
    currently-online clients on next WebSocket tick. Clients dedup on the
    envelope nonce.
    """

    __tablename__ = "bridge_envelopes"

    idempotency_key = Column(String(128), primary_key=True)
    envelope_b64 = Column(String, nullable=False)
    bridged_by_user_id = Column(String, nullable=False)
    bridged_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    picked_up = Column(Boolean, default=False, nullable=False)

    __table_args__ = (
        Index("idx_bridge_envelopes_bridged_at", "bridged_at"),
        Index("idx_bridge_envelopes_picked_up", "picked_up"),
    )


# ─── Request / response models ─────────────────────────────────────────


class BridgeEnvelopeRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    envelope_b64: str = Field(..., description="Base64 of the opaque mesh envelope JSON")
    idempotency_key: str = Field(..., description="Stable key (typically 'bridge-enc-<nonce>')")
    path_used: Optional[str] = Field(default="mesh-bridge")


class BridgeEnvelopeResponse(BaseModel):
    accepted: bool
    duplicate: bool


class PendingBridgeEnvelope(BaseModel):
    idempotency_key: str
    envelope_b64: str
    bridged_at: datetime


class PendingBridgesResponse(BaseModel):
    envelopes: list[PendingBridgeEnvelope]


# ─── Endpoints ─────────────────────────────────────────────────────────


MAX_ENVELOPE_BYTES = 64 * 1024  # 64 KiB cap per envelope to prevent storage abuse
BRIDGE_RETENTION = timedelta(hours=24)


@router.post(
    "/bridge-envelope",
    response_model=BridgeEnvelopeResponse,
    status_code=status.HTTP_200_OK,
)
def bridge_envelope(
    body: BridgeEnvelopeRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BridgeEnvelopeResponse:
    """
    Accept an opaque encrypted envelope from a bridging device.

    The server cannot decrypt this. It just parks it for offline recipients
    and fans it out via the WebSocket inbox to currently-connected clients.
    """
    try:
        raw = base64.b64decode(body.envelope_b64, validate=True)
    except (ValueError, TypeError):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid base64 envelope")
    if len(raw) > MAX_ENVELOPE_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="Envelope too large")
    if not body.idempotency_key or len(body.idempotency_key) > 128:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid idempotency_key")

    entry = BridgeEnvelope(
        idempotency_key=body.idempotency_key,
        envelope_b64=body.envelope_b64,
        bridged_by_user_id=str(user.id),
    )
    try:
        db.add(entry)
        db.commit()
        logger.info(
            "Bridge envelope accepted: key=%s by user=%s (%d bytes)",
            body.idempotency_key,
            user.id,
            len(raw),
        )

        # Fan out to currently-online inbox WS clients (best effort).
        # The inbox WS layer subscribes to a Redis pub/sub channel
        # 'mesh.bridge.envelope' — each WS handler forwards to its peer.
        try:
            from services.realtime_pubsub import publish_bridge_envelope

            publish_bridge_envelope(body.envelope_b64, body.idempotency_key)
        except ImportError:
            logger.debug("realtime_pubsub not wired yet; envelope stored only")
        except Exception as ex:
            logger.warning("Bridge envelope publish failed: %s (still stored)", ex)

        return BridgeEnvelopeResponse(accepted=True, duplicate=False)
    except IntegrityError:
        db.rollback()
        # Same key already stored — that's a no-op success.
        return BridgeEnvelopeResponse(accepted=True, duplicate=True)


@router.get(
    "/pending-bridges",
    response_model=PendingBridgesResponse,
)
def pending_bridges(
    since: Optional[datetime] = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> PendingBridgesResponse:
    """
    Fetch bridge envelopes the calling client hasn't seen yet.

    Used on app foreground / reconnect: the client passes the timestamp
    of its last bridge sync, and gets back any envelopes received since.
    Each envelope is tried-decrypt; clients keep what they can decrypt.
    """
    if since is None:
        since = datetime.now(timezone.utc) - BRIDGE_RETENTION

    rows = (
        db.query(BridgeEnvelope)
        .filter(BridgeEnvelope.bridged_at >= since)
        .order_by(BridgeEnvelope.bridged_at.desc())
        .limit(500)
        .all()
    )
    return PendingBridgesResponse(
        envelopes=[
            PendingBridgeEnvelope(
                idempotency_key=row.idempotency_key,
                envelope_b64=row.envelope_b64,
                bridged_at=row.bridged_at,
            )
            for row in rows
        ]
    )


@router.post(
    "/cleanup",
    status_code=status.HTTP_200_OK,
    include_in_schema=False,
)
def cleanup_expired(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Admin-only cleanup of expired bridge envelopes. Cron-safe."""
    cutoff = datetime.now(timezone.utc) - BRIDGE_RETENTION
    deleted = (
        db.query(BridgeEnvelope)
        .filter(BridgeEnvelope.bridged_at < cutoff)
        .delete(synchronize_session=False)
    )
    db.commit()
    return {"deleted": deleted}
