"""
Mesh-to-Internet Gateway router (v1.6 contract → v1.7 storage).

These endpoints back the iOS `MeshGatewayService` from app builds that
shipped with the v1.6 wire format. v1.7 split the bridge surface into
the cleaner `/api/mesh/bridge-envelope` + `/api/mesh/pending-bridges`
pair, but a non-trivial install base (TestFlight + production) still
posts to the v1.6 paths.

To keep the network mixed-version-safe, this router is no longer a
stub — every endpoint here forwards into the same `bridge_envelopes`
table and pub/sub channel that `mesh.py` uses. Concretely:

  • POST /api/gateway/relay → translate `RelayRequest` to a
    `BridgeEnvelope` row and publish on the `mesh.bridge.envelope`
    pub/sub channel. v1.7 receivers (which drain
    `/api/mesh/pending-bridges` and listen for `bridge_envelope` WS
    events) will see envelopes from v1.6 senders.
  • GET /api/gateway/pending/{neighbor_id} → return the same set of
    24-hour bridge envelopes that `/api/mesh/pending-bridges` returns,
    re-shaped as `InboundEnvelope`s. This lets v1.6 receivers (which
    only know the gateway-prefixed routes) drain envelopes posted via
    the v1.7 `/api/mesh/bridge-envelope` path.
  • POST /api/gateway/heartbeat → still informational; ranking lands
    in a later cycle.

The original `RelayResponse` / `PendingResponse` shapes are preserved
verbatim so the v1.6 client decoder is happy.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field
from typing import List, Optional
from datetime import datetime, timezone
import base64
import logging

from database import get_db
from models import User
from routers.users import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/gateway", tags=["gateway"])


# ─────────────────────────────────────────────────────────────────────
# Request / response models
# ─────────────────────────────────────────────────────────────────────


class RelayRequest(BaseModel):
    """An offline neighbour's outbound envelope, forwarded by an
    online gateway. The server treats `payload` as opaque bytes — the
    original sender already E2EE-sealed it. We only need
    `recipient_hint` to route."""

    recipient_hint: str = Field(..., min_length=1, max_length=128)
    payload: bytes = Field(..., max_length=512_000)  # 500 KB hard cap
    nonce: bytes = Field(..., min_length=8, max_length=64)
    created_at: float


class RelayResponse(BaseModel):
    status: str
    accepted_at: float


class HeartbeatRequest(BaseModel):
    """Gateway publishes its current score + capacity so the server
    can rank gateways for opportunistic backfill."""

    gateway_device_id: str = Field(..., min_length=1, max_length=128)
    score: float = Field(..., ge=0.0, le=1.0)
    capacity_bytes_per_second: int = Field(..., ge=0, le=10_000_000)


class HeartbeatResponse(BaseModel):
    status: str
    next_heartbeat_seconds: int


class InboundEnvelope(BaseModel):
    """An inbound envelope destined for an offline neighbour, ready
    for the gateway to re-broadcast over BLE."""

    recipient_hint: str
    payload: bytes
    server_nonce: bytes
    queued_at: float


class PendingResponse(BaseModel):
    envelopes: List[InboundEnvelope]
    next_poll_seconds: int


# Replay-window guard for v1.6 `created_at`-stamped requests. The
# bridge_envelopes primary key handles per-envelope dedup; this is a
# cheap sanity filter for clock-skew or replay attacks.
_REPLAY_WINDOW_SECONDS = 600  # 10 min


# ─────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────


@router.post("/relay", response_model=RelayResponse, status_code=status.HTTP_202_ACCEPTED)
async def relay(
    body: RelayRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Accept an outbound relay request from an authenticated gateway.

    Cross-version compatibility: v1.6 clients still POST here. We
    translate into the v1.7 `BridgeEnvelope` row and fan out via the
    same pub/sub channel `/api/mesh/bridge-envelope` uses, so v1.7
    receivers see envelopes from v1.6 senders without the v1.6 client
    needing to know about the new path.
    """
    now = datetime.now(timezone.utc).timestamp()

    # Replay window is still useful — v1.6 clients stamp `created_at`
    # on the offline node and we don't want stale relays sneaking in
    # hours later. The bridge_envelopes primary key handles dedup, so
    # the in-process `_seen_nonces` ring is now redundant; we keep
    # this single timestamp check as a cheap sanity filter.
    if abs(now - body.created_at) > _REPLAY_WINDOW_SECONDS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="created_at outside replay window",
        )

    # Map v1.6 (`payload`+`nonce` bytes) → v1.7 (`envelope_b64`+
    # `idempotency_key` strings). Pydantic decoded the inbound base64
    # for us; we re-encode for storage as text.
    envelope_b64 = base64.b64encode(body.payload).decode("ascii")
    idempotency_key = base64.b64encode(body.nonce).decode("ascii")

    # Import lazily to avoid a circular import between gateway.py and
    # mesh.py at module load time (both are pulled into main.py's
    # router list in the same pass).
    from routers.mesh import BridgeEnvelope, MAX_ENVELOPE_BYTES

    if len(body.payload) > MAX_ENVELOPE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="Envelope too large",
        )
    if len(idempotency_key) > 128:
        # Shouldn't trip — RelayRequest already caps nonce ≤ 64 bytes
        # (≈ 88 base64 chars) — but the bridge_envelopes column is
        # varchar(128), so we guard explicitly.
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="nonce too long",
        )

    entry = BridgeEnvelope(
        idempotency_key=idempotency_key,
        envelope_b64=envelope_b64,
        bridged_by_user_id=str(current_user.id),
    )
    try:
        db.add(entry)
        db.commit()
    except IntegrityError:
        db.rollback()
        # Same envelope twice from any gateway — client retry, not an
        # error. v1.6 clients expect "duplicate" instead of an HTTP
        # error here.
        return RelayResponse(status="duplicate", accepted_at=now)

    try:
        from services.realtime_pubsub import publish_bridge_envelope

        publish_bridge_envelope(envelope_b64, idempotency_key)
    except ImportError:
        logger.debug("realtime_pubsub not wired yet; envelope stored only")
    except Exception as ex:
        logger.warning("Bridge envelope publish failed: %s (still stored)", ex)

    return RelayResponse(status="accepted", accepted_at=now)


@router.post("/heartbeat", response_model=HeartbeatResponse)
async def heartbeat(
    body: HeartbeatRequest,
    current_user: User = Depends(get_current_user),
):
    """Gateway tells us 'I am up, this is my score, this is my
    capacity.' We use this in v1.7 to rank gateways when several are
    available for the same offline neighbour.

    For v1.6 we acknowledge and tell the client when to come back.
    """
    return HeartbeatResponse(status="ok", next_heartbeat_seconds=60)


@router.get("/pending/{neighbor_id}", response_model=PendingResponse)
async def pending(
    neighbor_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Gateway pulls inbound envelopes destined for a specific offline
    neighbour it has seen on BLE.

    Cross-version compatibility: returns the same set of bridge
    envelopes that `/api/mesh/pending-bridges` exposes, re-shaped into
    the v1.6 `InboundEnvelope` wire form. The bridge envelope is
    opaque to the server, so we cannot filter by `neighbor_id` — the
    client decrypts every entry it can and silently drops the rest.
    Same approach `MeshBridgeReceiver` already uses on v1.7.
    """
    if not neighbor_id or len(neighbor_id) > 128:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="invalid neighbor_id",
        )

    # 🔴 hacker-audit 2026-05-19: this v1.6-compat endpoint kept the
    # *old* posture — 500 envelopes, 24h window, no rate limit — and
    # thereby undid the round-26 hardening on the v1.7 sibling
    # /api/mesh/pending-bridges. An attacker could just call the
    # gateway twin to resume bulk envelope harvesting. Same three
    # defences now apply: rate limit, smaller cap, narrower window.
    try:
        from middleware.rate_limit import rate_limiter
        rate_limiter.check_rate_limit(
            identifier=f"gateway_pending:{current_user.id}",
            max_attempts=10,
            window_minutes=1,
            lockout_minutes=1,
        )
    except HTTPException:
        raise
    except ImportError:
        logger.error("gateway /pending: rate_limiter unavailable — fail closed")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="rate limiter unavailable",
        )
    except Exception as e:
        logger.error("gateway /pending: rate limit crashed: %s — fail closed", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="rate limiter error",
        )

    from datetime import timedelta as _td
    from routers.mesh import BridgeEnvelope

    cutoff = datetime.now(timezone.utc) - _td(hours=1)
    rows = (
        db.query(BridgeEnvelope)
        .filter(BridgeEnvelope.bridged_at >= cutoff)
        .order_by(BridgeEnvelope.bridged_at.desc())
        .limit(50)
        .all()
    )

    envelopes: List[InboundEnvelope] = []
    for row in rows:
        try:
            payload = base64.b64decode(row.envelope_b64, validate=True)
        except (ValueError, TypeError):
            # Stored row is malformed — skip rather than poison the
            # whole batch. Production envelopes are always base64.
            continue
        # `server_nonce` is opaque dedup material to the v1.6 receiver
        # — it just compares bytes against its seen-nonces ring. Bridge
        # envelopes posted via `/api/mesh/bridge-envelope` may use a
        # human-readable `idempotency_key` (e.g. `bridge-enc-<nonce>`),
        # which isn't a valid base64 nonce. Hand back the UTF-8 bytes
        # of the key directly: same uniqueness guarantee, no parse step
        # that would silently drop interop envelopes.
        envelopes.append(
            InboundEnvelope(
                recipient_hint=neighbor_id,
                payload=payload,
                server_nonce=row.idempotency_key.encode("utf-8"),
                queued_at=row.bridged_at.timestamp(),
            )
        )

    return PendingResponse(envelopes=envelopes, next_poll_seconds=30)
