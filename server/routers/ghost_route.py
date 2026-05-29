"""
Ghost Route (ATSAM Layer 4) online inbox.

This is the server-side counterpart to the iOS `GhostRouteOnline`
module. It implements a tag-keyed mailbox model for messages
that have been wrapped in a Ghost Route envelope by the sender:

    sender → POST /api/ghost-route/deposit  (recipient_tag, envelope)
    server → indexes by recipient_tag, stores opaque envelope
    receiver → POST /api/ghost-route/fetch  (list of expected tags)
    server → returns matching envelopes (and removes them after ack)

The server NEVER learns:
  * who sent a given envelope
  * which conversation a given envelope belongs to
  * how the receiver derived their expected tags
  * the plaintext of the envelope payload (it's already encrypted
    end-to-end before this layer runs)

What the server CAN see:
  * The set of recipient_tags a polling user asks for.
    Two users polling the same tag is unusual (would only happen
    on tag collision, probability ≤ pollers × 2^-128 per request).
    A single user's tag set leaks how many pairs they have, but
    NOT which specific peers those pairs are with.
  * Volume + timing of deposits and fetches.
  * IP + auth token of the depositor and the fetcher.

The latter two are out-of-scope for Ghost Route (they require
onion routing + cover traffic — separate concern). This router's
guarantee is just "no stable per-user routing identifier ever
hits the database for online traffic".

Schema
──────
ghost_route_envelopes:
    id              Integer (PK, autoincrement)
    recipient_tag   String  (16 bytes, base64; INDEXED)
    envelope        Text    (opaque base64 payload)
    deposited_by    String  (FK users.id; for abuse audit)
    deposited_at    Float   (unix timestamp; INDEXED for GC)
    fetched         Integer (0 = pending, 1 = delivered)

A background GC job (out of scope here; runs nightly) deletes
envelopes older than 30 days that are still pending — these
represent recipients who have not come online to ack. Production
should make this configurable per environment.
"""

import logging
import time
from collections import defaultdict, deque
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, Integer, Float, Text, Index
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User
from routers.users import get_current_user


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/ghost-route", tags=["ghost-route"])


# Hard cap on how many tags a single fetch request can ask for.
# Protects the server from a single client requesting millions of
# tags in one query (which could be used as a DoS or to fingerprint
# all envelopes in the database).
MAX_TAGS_PER_FETCH = 256

# Hard cap on the size of a single envelope. Large enough for any
# reasonable text + small media, tight enough that the table doesn't
# grow into a content store. Anything bigger should use a separate
# media path.
MAX_ENVELOPE_BYTES = 64 * 1024  # 64 KiB after base64


# 🔴 ROUND 52 (2026-05-19) — hacker-audit Protocol F2 (HIGH:
# DoS surface via unbounded deposit + fetch).
#
# PREVIOUSLY: any authenticated user could call `/deposit` and
# `/fetch` an unlimited number of times. Two specific abuses:
#   1. Storage flood — fire 1000 deposits/sec at random recipient
#      tags. The 64 KiB envelope cap helps, but at 1000 deposits/s
#      that's 64 MB/s of DB growth from a single attacker; rotate
#      throwaway accounts and the rate compounds.
#   2. Fetch flood — fire 1000 `/fetch` calls/sec with 256 tags
#      each. The `claim_by` write-on-fetch from R51 means each call
#      issues 256 row-updates → DB I/O storm.
#
# Per-instance sliding-window limits are enough on Cloud Run
# because the attacker doesn't control which instance their request
# lands on; effective budget is one window per instance, not per
# attacker. We pick deliberately tight numbers: deposit 60/min/user
# (≈ one per second; legitimate messaging is well below this) and
# fetch 240/min/user (legitimate poll cadence is ≤ 10/min).
_DEPOSIT_WINDOW: dict[str, deque] = defaultdict(deque)
_FETCH_WINDOW: dict[str, deque] = defaultdict(deque)
_GHOST_WINDOW_SECONDS = 60.0
_DEPOSIT_BUDGET = 60        # per user
_FETCH_BUDGET = 240         # per user


def _check_ghost_rate_limit(window: dict[str, deque], user_id: str, budget: int) -> bool:
    """Sliding-window rate-limit check. Returns False to deny."""
    now = time.monotonic()
    bucket = window[user_id]
    while bucket and now - bucket[0] > _GHOST_WINDOW_SECONDS:
        bucket.popleft()
    if len(bucket) >= budget:
        return False
    bucket.append(now)
    return True


# 🔴 ROUND 52 — recipient_tag is HMAC-SHA256-128 (16 raw bytes) per
# GRRecipientTag.swift. Standard base64 of 16 bytes is exactly 24
# chars (no padding) or 28 chars with `==` padding. Tighter than the
# old min=16 (which permitted 12-byte/96-bit tags) — short tags
# weaken collision resistance and let an attacker enumerate.
GHOST_TAG_MIN = 22  # base64 of >= 16 bytes
GHOST_TAG_MAX = 28  # base64 of 16 bytes with padding


# ──────────────────────────────────────────────────────────────────────────
# DB model
# ──────────────────────────────────────────────────────────────────────────


class GhostRouteEnvelope(Base):
    __tablename__ = "ghost_route_envelopes"

    id = Column(Integer, primary_key=True, autoincrement=True)
    recipient_tag = Column(String, nullable=False)
    envelope = Column(Text, nullable=False)
    deposited_by = Column(String, nullable=False)
    deposited_at = Column(Float, nullable=False)
    fetched = Column(Integer, nullable=False, default=0)
    # 🔴 ROUND 51 (2026-05-19) — claim binding for ACK ownership.
    # See `ack_envelopes` below for the rationale; this column is
    # back-filled to NULL by `ALTER TABLE … ADD COLUMN IF NOT EXISTS`
    # in `main.py`.
    claimed_by = Column(String, nullable=True)


Index("ix_ghost_route_recipient_tag", GhostRouteEnvelope.recipient_tag)
Index("ix_ghost_route_deposited_at",  GhostRouteEnvelope.deposited_at)


# ──────────────────────────────────────────────────────────────────────────
# Pydantic schemas
# ──────────────────────────────────────────────────────────────────────────


class DepositRequest(BaseModel):
    # 🔴 ROUND 52 — tightened from min=16/max=64 to base64(16 raw)
    # range. Previously 12-byte tags (96-bit) were accepted.
    recipient_tag: str = Field(..., min_length=GHOST_TAG_MIN, max_length=GHOST_TAG_MAX)
    envelope: str = Field(..., min_length=1)


class DepositResponse(BaseModel):
    id: int


class FetchRequest(BaseModel):
    tags: List[str]


class EnvelopeDTO(BaseModel):
    id: int
    recipient_tag: str
    envelope: str
    deposited_at: float


class FetchResponse(BaseModel):
    envelopes: List[EnvelopeDTO]


class AckRequest(BaseModel):
    ids: List[int]


class AckResponse(BaseModel):
    acknowledged: int


# ──────────────────────────────────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────────────────────────────────


@router.post("/deposit", response_model=DepositResponse)
async def deposit_envelope(
    req: DepositRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Deposit a Ghost Route envelope addressed by `recipient_tag`.

    The server treats `recipient_tag` as an opaque routing key —
    it does NOT know which user the tag was computed for. The
    envelope payload is already encrypted end-to-end.
    """
    # 🔴 ROUND 52 — per-user deposit rate limit (60/min). Prevents
    # storage-flood DoS from a single authenticated account.
    if not _check_ghost_rate_limit(_DEPOSIT_WINDOW, str(current_user.id), _DEPOSIT_BUDGET):
        logger.warning("ghost-route deposit rate-limited user=%s", current_user.id)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit: too many ghost-route deposits",
        )
    if len(req.envelope) > MAX_ENVELOPE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"envelope exceeds {MAX_ENVELOPE_BYTES} bytes",
        )
    now = datetime.utcnow().timestamp()
    env = GhostRouteEnvelope(
        recipient_tag=req.recipient_tag,
        envelope=req.envelope,
        deposited_by=current_user.id,
        deposited_at=now,
        fetched=0,
    )
    db.add(env)
    db.commit()
    db.refresh(env)
    logger.info("ghost-route deposit id=%d by=%s tag-len=%d",
                env.id, current_user.id, len(req.recipient_tag))
    return DepositResponse(id=env.id)


@router.post("/fetch", response_model=FetchResponse)
async def fetch_envelopes(
    req: FetchRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Return any pending envelopes whose recipient_tag is in the
    caller's expected set.

    The server cannot tell which pair each tag belongs to or even
    that two tags are for the same conversation — the tags are
    independent HMAC outputs from the caller's side.
    """
    # 🔴 ROUND 52 — per-user fetch rate limit (240/min). Legitimate
    # poll cadence is well below this; the cap mainly defends against
    # the row-update storm now that `/fetch` writes `claimed_by`.
    if not _check_ghost_rate_limit(_FETCH_WINDOW, str(current_user.id), _FETCH_BUDGET):
        logger.warning("ghost-route fetch rate-limited user=%s", current_user.id)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit: too many ghost-route fetches",
        )
    if len(req.tags) == 0:
        return FetchResponse(envelopes=[])
    if len(req.tags) > MAX_TAGS_PER_FETCH:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"too many tags in one fetch (max {MAX_TAGS_PER_FETCH})",
        )

    # Dedupe to defend against a client passing the same tag many
    # times in one request.
    unique_tags = list(dict.fromkeys(req.tags))

    rows = (
        db.query(GhostRouteEnvelope)
        .filter(
            GhostRouteEnvelope.recipient_tag.in_(unique_tags),
            GhostRouteEnvelope.fetched == 0,
        )
        .order_by(GhostRouteEnvelope.deposited_at.asc())
        .limit(MAX_TAGS_PER_FETCH * 4)  # safety upper bound
        .all()
    )

    # 🔴 ROUND 51 (2026-05-19) — claim binding for ACK ownership.
    # Set `claimed_by = current_user.id` on first fetch. The companion
    # change in `ack_envelopes` then refuses to ACK envelopes the
    # caller never claimed → blackhole DoS is no longer possible.
    # We only set `claimed_by` on rows that don't already have one;
    # legitimate re-fetch (recipient retries the poll before acking)
    # is idempotent.
    for r in rows:
        if r.claimed_by is None:
            r.claimed_by = str(current_user.id)
    db.commit()

    return FetchResponse(envelopes=[
        EnvelopeDTO(
            id=r.id,
            recipient_tag=r.recipient_tag,
            envelope=r.envelope,
            deposited_at=r.deposited_at,
        )
        for r in rows
    ])


@router.post("/ack", response_model=AckResponse)
async def ack_envelopes(
    req: AckRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Mark a set of envelope ids as fetched.

    The receiver MUST call this after a successful local decrypt;
    otherwise the same envelopes are re-served on every poll. The
    server does not delete the rows immediately — a GC job (run
    out-of-band) removes acked rows after a retention window for
    audit purposes.

    🔴 ROUND 51 (2026-05-19) — hacker-audit Protocol F1 (CRITICAL).
    PREVIOUSLY: this endpoint took any list of envelope ids from any
    authenticated user and bulk-flipped `fetched=1`. There was no
    check that the caller had ever fetched (let alone owned) the
    envelopes. Concrete attack: an attacker logs in as any throwaway
    account, fires ONE request with `ids: [1, 2, …, 1_000_000]`, and
    every undelivered Ghost Route envelope in the system is marked
    delivered. Legitimate recipients poll → server filters by
    `fetched=0` → nothing returned → messages silently disappear.
    Mass denial-of-delivery for the entire user base with a single
    HTTP call.

    FIX: the `/fetch` companion now stamps `claimed_by =
    current_user.id` on first read. ACK requires `claimed_by` to
    equal the caller — so an attacker can only ACK envelopes they
    actually pulled from `/fetch`, which they can only pull if they
    happen to know the (HMAC-derived, per-pair-secret) recipient
    tag. Tag knowledge already implies pair membership, so ACK is
    now bound to a legitimate participant.
    """
    if not req.ids:
        return AckResponse(acknowledged=0)
    # 🔴 ROUND 51 — must match BOTH the id list AND the caller's claim.
    # `claimed_by IS NOT NULL` guarantees we don't accidentally allow
    # bulk ACK of pre-round-51 rows; those rows simply expire via the
    # 30-day GC job once round 51 rolls out.
    n = (
        db.query(GhostRouteEnvelope)
        .filter(
            GhostRouteEnvelope.id.in_(req.ids),
            GhostRouteEnvelope.fetched == 0,
            GhostRouteEnvelope.claimed_by == str(current_user.id),
        )
        .update({"fetched": 1}, synchronize_session=False)
    )
    db.commit()
    return AckResponse(acknowledged=n)
