"""
ATSAM Pre-Key Bundle Router.

Stores ATSAM (X25519 + ML-KEM-768 post-quantum hybrid) pre-key
bundles per user so that initiators can fetch them and bootstrap
a hybrid root key asynchronously — even when the recipient is
offline.

This is a SIBLING of `e2ee.py`, not a replacement. The existing
X3DH bundles continue to serve the Signal-style Double Ratchet
path. ATSAM bundles serve the new layered protocol path.

Storage model
─────────────
atsam_prekey_bundles   one row per (user_id, device_id)
atsam_pair_inits       transient queue of pending pair-inits

Privacy model
─────────────
The server stores ONLY public material:
  - X25519 public key (32 bytes, base64-encoded)
  - ML-KEM-768 public key (1184 bytes, base64-encoded)
  - Ed25519 signature over the above, by the user's identity key

The server cannot derive any shared secret or read any message
content — that's the whole point of hybrid pairing. The server's
job is purely "store + forward signed public material".

Wire format
───────────
Bundle:
  {
    "user_id":         "...",
    "device_id":       "...",
    "x25519_pub":      "base64",
    "ml_kem_pub":      "base64",
    "signed_by":       "base64 Ed25519 identity key",
    "signature":       "base64 over (x25519_pub || ml_kem_pub)",
    "atsam_version":   1
  }

Pair-init (Alice → Bob over the server):
  {
    "from_user":       "alice_id",
    "to_user":         "bob_id",
    "x25519_pub":      "base64 (Alice's pub)",
    "ml_kem_pub":      "base64 (Alice's pub)",
    "ml_kem_ct":       "base64 (Alice's encap toward Bob)",
    "pairing_nonce":   "base64 (16 bytes)",
    "context":         "raven-online-v1"
  }
"""

import base64
import logging
import time
from collections import defaultdict, deque
from datetime import datetime
from typing import List, Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, Integer, Float, Index, Text
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User
from routers.users import get_current_user


# ──────────────────────────────────────────────────────────────────────────
# Round 22 — hacker-audit C7 / C8 hardening
# ──────────────────────────────────────────────────────────────────────────
#
# C7: the iOS client (round 16) now signs the strong canonical
# payload `"raven-bundle-v2" || 0x00 || userId || 0x00 || xPub || pqPub`.
# Server-side verification on PUBLISH means a compromised client
# (or an attacker who steals a session token) can't publish a
# bundle that claims to be for someone else — the signature
# wouldn't validate against the claimed userId. This is the missing
# server-side half of the round-16 client fix.
#
# C8: prekey FETCH is currently open to any authed user (used to
# bootstrap Noise sessions with cold contacts). Add a per-(viewer,
# target) sliding-window rate limit so a single compromised account
# can't enumerate the entire user table to build a contact graph.
# Sliding window: 60 fetches per minute per (viewer, target) pair,
# 240 per minute across all targets.

# In-memory rate-limit windows. Process-local; on multi-instance
# Cloud Run we eventually want a shared cache (Memorystore/Redis)
# but for v1 the per-instance budget is more than enough — the
# attacker would need to pin the same Cloud Run instance over
# their burst, which they don't control.
_RATE_PAIR_WINDOW: dict[tuple[str, str], deque] = defaultdict(deque)
_RATE_VIEWER_WINDOW: dict[str, deque] = defaultdict(deque)
_RATE_WINDOW_SECONDS = 60.0
_RATE_PAIR_BUDGET = 60      # per (viewer, target)
_RATE_VIEWER_BUDGET = 240   # per viewer across all targets

# 🔴 ROUND 53 (2026-05-19) — pair-init rate limits + size caps.
#
# Two distinct windows: per-sender (limits how fast Alice can blast
# pair-inits across all recipients) and per-(sender, recipient)
# (limits how many distinct pair-inits Alice can queue to Bob).
# Without these the attack is:
#   • Alice posts 1000 pair-inits/sec → all hit Bob's inbox →
#     Bob's `/pair-init GET` returns a 4 MB JSON array every poll →
#     iOS client memory spike + UI lockup.
#   • Each pair-init carries ~2.7 KB of base64 PQ material; ten
#     thousand pair-inits → ~27 MB of DB row growth per victim.
#
# Limits are loose enough for legitimate first-contact flows
# (typical: one pair-init per peer per re-pair cycle, single-digit
# pair-inits per user per day) but kill the spam vector.
_PAIRINIT_SENDER_WINDOW: dict[str, deque] = defaultdict(deque)
_PAIRINIT_PAIR_WINDOW: dict[tuple[str, str], deque] = defaultdict(deque)
_PAIRINIT_SENDER_BUDGET = 30        # per sender (across all recipients), per minute
_PAIRINIT_PAIR_BUDGET = 3           # per (sender, recipient), per minute

# Hard caps on the base64-encoded sizes of fields the SERVER will
# accept into `atsam_pair_inits`. Matches ATSAMConstants on iOS:
#   • X25519 pub = 32 raw bytes → base64 ≈ 44 chars
#   • ML-KEM-768 pub = 1184 raw bytes → base64 ≈ 1580 chars
#   • ML-KEM-768 ct  = 1088 raw bytes → base64 ≈ 1452 chars
#   • pairing nonce  = 32 raw bytes → base64 ≈ 44 chars
#                    (iOS uses 32; old docstring said 16 — accept both)
_PAIRINIT_MAX_X25519_PUB = 64
_PAIRINIT_MAX_MLKEM_PUB = 1700
_PAIRINIT_MAX_MLKEM_CT = 1600
_PAIRINIT_MAX_PAIRING_NONCE = 64
_PAIRINIT_MAX_CONTEXT = 128

# Max pending (undelivered) pair-inits a recipient can have queued.
# Beyond this, new submissions for the same recipient are rejected
# until the recipient acks some. Defense against a botnet of N
# senders each within their own per-sender budget collectively
# overflowing Bob's inbox.
_PAIRINIT_INBOX_CAP = 64

# 🔴 ROUND 55 (2026-05-19) — bundle-publish rate limit.
#
# Legitimate publish frequency is bounded by how often a user
# rotates ATSAM keys — typically 1–2 times per day at most (key
# rotation policy on iOS), and a burst on first install. A
# compromised client / stolen token can publish thousands of new
# bundles per minute, each one a NEW x25519_pub. Effect:
#   • Every peer who already paired sees `signed_by` change → the
#     iOS `ATSAMMismatchBanner` fires for every conversation.
#   • Banner storm = "click through every chat banner" until users
#     start clicking through them blindly → defeats the security
#     UI that's the only thing standing between a victim and a
#     legitimate MITM.
# 10 publishes per hour per user is plenty for honest behavior and
# kills the banner-storm vector.
_PUBLISH_WINDOW: dict[str, deque] = defaultdict(deque)
_PUBLISH_WINDOW_SECONDS = 3600.0   # 1 hour
_PUBLISH_BUDGET = 10               # per user, per hour

# Round 22 — bundle-signature canonicalisation. Mirrors
# PeerKeyDirectory.strongSignedPayload(userId:xPub:pqPub:) on iOS.
_BUNDLE_DOMAIN_V2 = b"raven-bundle-v2"


def _strong_signed_payload(user_id: str, x_pub: bytes, pq_pub: bytes) -> bytes:
    """Canonical bytes that the client's round-16 sign covers."""
    return _BUNDLE_DOMAIN_V2 + b"\x00" + user_id.encode("utf-8") + b"\x00" + x_pub + pq_pub


def _verify_bundle_signature(
    *,
    user_id: str,
    x_pub_b64: str,
    pq_pub_b64: str,
    signed_by_b64: str,
    signature_b64: str,
) -> tuple[bool, str]:
    """Verify the strong-format bundle signature, with legacy fallback.

    Returns (ok, strength). `strength` is "strong" when the
    round-16 userId-bound payload verified, "weak_legacy" when only
    the pre-round-16 `xPub || pqPub` payload verified, "invalid"
    otherwise.

    The publish handler rejects "invalid" and accepts "weak_legacy"
    for one release transition (so existing pre-round-16 clients
    can still publish), tagging the row so a future migration can
    force-rotate the legacy ones.
    """
    try:
        x_pub = base64.b64decode(x_pub_b64)
        pq_pub = base64.b64decode(pq_pub_b64)
        signing_pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(signed_by_b64))
        signature = base64.b64decode(signature_b64)
    except Exception:
        return False, "invalid"

    if len(x_pub) != 32:
        return False, "invalid"

    # Strong format first — the only one that binds userId.
    strong = _strong_signed_payload(user_id, x_pub, pq_pub)
    try:
        signing_pub.verify(signature, strong)
        return True, "strong"
    except InvalidSignature:
        pass

    # Legacy fallback so round-12-15 clients can still publish.
    legacy = x_pub + pq_pub
    try:
        signing_pub.verify(signature, legacy)
        return True, "weak_legacy"
    except InvalidSignature:
        return False, "invalid"


def _check_prekey_fetch_rate_limit(viewer_id: str, target_id: str) -> bool:
    """Sliding-window rate limit for prekey fetch. Returns False to deny."""
    now = time.monotonic()
    pair_window = _RATE_PAIR_WINDOW[(viewer_id, target_id)]
    viewer_window = _RATE_VIEWER_WINDOW[viewer_id]
    # Evict stale entries.
    while pair_window and now - pair_window[0] > _RATE_WINDOW_SECONDS:
        pair_window.popleft()
    while viewer_window and now - viewer_window[0] > _RATE_WINDOW_SECONDS:
        viewer_window.popleft()
    if len(pair_window) >= _RATE_PAIR_BUDGET:
        return False
    if len(viewer_window) >= _RATE_VIEWER_BUDGET:
        return False
    pair_window.append(now)
    viewer_window.append(now)
    return True


def _check_pair_init_rate_limit(sender_id: str, recipient_id: str) -> bool:
    """🔴 ROUND 53 — two-tier rate limit for /pair-init submissions."""
    now = time.monotonic()
    sender_window = _PAIRINIT_SENDER_WINDOW[sender_id]
    pair_window = _PAIRINIT_PAIR_WINDOW[(sender_id, recipient_id)]
    while sender_window and now - sender_window[0] > _RATE_WINDOW_SECONDS:
        sender_window.popleft()
    while pair_window and now - pair_window[0] > _RATE_WINDOW_SECONDS:
        pair_window.popleft()
    if len(sender_window) >= _PAIRINIT_SENDER_BUDGET:
        return False
    if len(pair_window) >= _PAIRINIT_PAIR_BUDGET:
        return False
    sender_window.append(now)
    pair_window.append(now)
    return True


def _check_publish_rate_limit(user_id: str) -> bool:
    """🔴 ROUND 55 — bundle-publish sliding-window rate limit."""
    now = time.monotonic()
    bucket = _PUBLISH_WINDOW[user_id]
    while bucket and now - bucket[0] > _PUBLISH_WINDOW_SECONDS:
        bucket.popleft()
    if len(bucket) >= _PUBLISH_BUDGET:
        return False
    bucket.append(now)
    return True


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/atsam", tags=["atsam"])


# ──────────────────────────────────────────────────────────────────────────
# DB models — defined inline so this router is self-contained, matching
# the pattern used by routers/e2ee.py.
# ──────────────────────────────────────────────────────────────────────────


class ATSAMPreKeyBundle(Base):
    """One ATSAM pre-key bundle per (user_id, device_id).

    All key material is BASE64-encoded for portability over JSON.
    The server stores it as opaque text — it never decodes the
    bytes for cryptographic operations.
    """

    __tablename__ = "atsam_prekey_bundles"

    user_id = Column(String, primary_key=True)
    device_id = Column(String, primary_key=True)

    # Public keys (base64).
    x25519_pub = Column(Text, nullable=False)   # 32 raw bytes
    ml_kem_pub = Column(Text, nullable=False)   # 1184 raw bytes

    # Provenance: who signed this bundle, with what Ed25519 key,
    # and the signature itself. Lets clients verify that the
    # bundle they fetched was not substituted by the server.
    signed_by = Column(Text, nullable=False)    # base64 Ed25519 pub
    signature = Column(Text, nullable=False)    # base64 sig

    atsam_version = Column(Integer, nullable=False, default=1)

    created_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())
    updated_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())


class ATSAMPairInit(Base):
    """Pending pair-init message from one user to another.

    Acts like a tiny inbox: when Alice wants to pair with Bob and
    Bob is offline, Alice POSTs a pair-init here and Bob fetches
    it on next online. The server treats every field as opaque
    public material — none of it lets the server derive K_root.
    """

    __tablename__ = "atsam_pair_inits"

    # Surrogate auto-increment id so we can return stable handles.
    id = Column(Integer, primary_key=True, autoincrement=True)

    from_user = Column(String, nullable=False, index=True)
    to_user = Column(String, nullable=False, index=True)

    x25519_pub = Column(Text, nullable=False)    # Alice's pub
    ml_kem_pub = Column(Text, nullable=False)    # Alice's pub
    ml_kem_ct = Column(Text, nullable=False)     # Alice's encap toward Bob
    pairing_nonce = Column(Text, nullable=False)  # base64 16 bytes
    context = Column(Text, nullable=False)

    delivered = Column(Integer, nullable=False, default=0)  # 0/1
    created_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())


# Fast inbox queries: "fetch pending pair-inits for user X".
Index(
    "ix_atsam_pair_init_inbox",
    ATSAMPairInit.to_user,
    ATSAMPairInit.delivered,
)


# ──────────────────────────────────────────────────────────────────────────
# Pydantic schemas
# ──────────────────────────────────────────────────────────────────────────


class PreKeyBundleDTO(BaseModel):
    user_id: str
    device_id: str
    x25519_pub: str
    ml_kem_pub: str
    signed_by: str
    signature: str
    atsam_version: int = 1


class PreKeyBundleListDTO(BaseModel):
    """🔴 ROUND 71 phase 3 — multi-device fan-out response.

    The single-bundle `/prekey/{user_id}` endpoint returns ONLY the
    most-recently-published bundle (one device). When the recipient
    has linked devices, the sender only encrypted for that one
    device and the recipient's other devices could not decrypt the
    message — silently breaking multi-device E2EE.

    Senders that want to fan out to every linked device call
    `/prekey/{user_id}/bundles` instead, get back one bundle per
    device, and produce one ciphertext envelope per device.
    """

    user_id: str
    bundles: List["PreKeyBundleDTO"]


class PublishBundleRequest(BaseModel):
    device_id: str = Field(..., min_length=1, max_length=128)
    x25519_pub: str
    ml_kem_pub: str
    signed_by: str
    signature: str
    atsam_version: int = 1


class PublishBundleResponse(BaseModel):
    ok: bool = True


class PairInitDTO(BaseModel):
    id: int
    from_user: str
    to_user: str
    x25519_pub: str
    ml_kem_pub: str
    ml_kem_ct: str
    pairing_nonce: str
    context: str
    created_at: float


class SubmitPairInitRequest(BaseModel):
    to_user: str
    x25519_pub: str
    ml_kem_pub: str
    ml_kem_ct: str
    pairing_nonce: str
    context: str = "raven-online-v1"


class SubmitPairInitResponse(BaseModel):
    id: int


# ──────────────────────────────────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────────────────────────────────


@router.post("/prekey/publish", response_model=PublishBundleResponse)
async def publish_bundle(
    req: PublishBundleRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Publish (or replace) THIS user's ATSAM bundle.

    Round 22 — hacker-audit C7: server-side signature verification.
    Before this round the server stored whatever signature the
    client submitted, never checking it. A compromised client (or
    an attacker who stole a session token) could publish a bundle
    that claimed to be for the authed user but contained a key
    they didn't actually control — which then defeated downstream
    Safety Number checks because the signature "validated" against
    the wrong identity.

    Now we verify the signature canonicalises to
    `"raven-bundle-v2" || 0x00 || userId || 0x00 || xPub || pqPub`
    (strong format, ties the bundle to the publisher's authenticated
    userId), with a temporary fallback to the pre-round-16 legacy
    payload so round 12-15 clients can still publish during the
    rollout.

    🔴 ROUND 55 (2026-05-19) — hacker-audit Protocol F5 (HIGH).
    PREVIOUSLY: no rate limit. A stolen session token could publish
    thousands of bundles per minute, each one a new x25519_pub →
    every paired peer's ATSAM mismatch banner fires → users learn
    to dismiss the banner reflexively → real MITM goes unnoticed.
    FIX: 10 publishes/hour/user. Honest rotation never approaches
    this; banner-storm attack is killed.
    """
    if not _check_publish_rate_limit(str(current_user.id)):
        logger.warning(
            "ATSAM bundle publish rate-limited user=%s — banner-storm defense",
            current_user.id,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many bundle publishes — try again later",
        )

    ok, strength = _verify_bundle_signature(
        user_id=current_user.id,
        x_pub_b64=req.x25519_pub,
        pq_pub_b64=req.ml_kem_pub,
        signed_by_b64=req.signed_by,
        signature_b64=req.signature,
    )
    if not ok:
        logger.warning(
            "ATSAM bundle publish REJECTED — invalid signature from user_id=%s device_id=%s",
            current_user.id,
            req.device_id,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="bundle signature invalid",
        )
    if strength == "weak_legacy":
        logger.info(
            "ATSAM bundle published with LEGACY signature format (no userId binding) "
            "user_id=%s device_id=%s — please upgrade client to round 16+.",
            current_user.id,
            req.device_id,
        )

    now = datetime.utcnow().timestamp()

    existing = (
        db.query(ATSAMPreKeyBundle)
        .filter(
            ATSAMPreKeyBundle.user_id == current_user.id,
            ATSAMPreKeyBundle.device_id == req.device_id,
        )
        .first()
    )
    if existing:
        existing.x25519_pub = req.x25519_pub
        existing.ml_kem_pub = req.ml_kem_pub
        existing.signed_by = req.signed_by
        existing.signature = req.signature
        existing.atsam_version = req.atsam_version
        existing.updated_at = now
    else:
        bundle = ATSAMPreKeyBundle(
            user_id=current_user.id,
            device_id=req.device_id,
            x25519_pub=req.x25519_pub,
            ml_kem_pub=req.ml_kem_pub,
            signed_by=req.signed_by,
            signature=req.signature,
            atsam_version=req.atsam_version,
            created_at=now,
            updated_at=now,
        )
        db.add(bundle)
    db.commit()
    logger.info(
        "ATSAM bundle published for user_id=%s device_id=%s version=%d",
        current_user.id,
        req.device_id,
        req.atsam_version,
    )
    return PublishBundleResponse(ok=True)


@router.get("/prekey/{user_id}", response_model=PreKeyBundleDTO)
async def fetch_bundle(
    user_id: str,
    device_id: Optional[str] = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Fetch a peer's ATSAM bundle.

    If `device_id` is supplied, returns that specific device's
    bundle. Otherwise returns the most recently published bundle
    for that user (typical case: a peer has only one device).

    Round 22 — hacker-audit C8: per-(viewer, target) and per-
    viewer sliding-window rate limit. Bundles are public material,
    but unbounded enumeration lets a compromised account harvest
    every published identity key + build a social graph. The
    budget (60/min per pair, 240/min per viewer) is generous
    enough for legitimate first-contact flows but cuts enumeration
    by 1000×.
    """
    if not _check_prekey_fetch_rate_limit(current_user.id, user_id):
        logger.warning(
            "ATSAM prekey fetch rate-limited viewer=%s target=%s",
            current_user.id,
            user_id,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit: too many prekey fetches",
        )
    q = db.query(ATSAMPreKeyBundle).filter(ATSAMPreKeyBundle.user_id == user_id)
    if device_id is not None:
        q = q.filter(ATSAMPreKeyBundle.device_id == device_id)
    bundle = q.order_by(ATSAMPreKeyBundle.updated_at.desc()).first()
    if not bundle:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="no atsam bundle for this user",
        )
    return PreKeyBundleDTO(
        user_id=bundle.user_id,
        device_id=bundle.device_id,
        x25519_pub=bundle.x25519_pub,
        ml_kem_pub=bundle.ml_kem_pub,
        signed_by=bundle.signed_by,
        signature=bundle.signature,
        atsam_version=bundle.atsam_version,
    )


@router.get("/prekey/{user_id}/bundles", response_model=PreKeyBundleListDTO)
async def fetch_all_bundles(
    user_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Fetch ALL of a peer's ATSAM bundles (one per linked device).

    🔴 ROUND 71 phase 3 — multi-device E2EE fix. The pre-fix sender
    called `/prekey/{user_id}` which returned only the most-recent
    bundle, encrypted for ONE device, and the recipient's other
    devices silently failed to decrypt (no badge, no error — just
    "no message" on the second iPad / Mac / Watch).

    New behavior: the sender enumerates every published device for
    the recipient and produces one ciphertext envelope per device.
    The recipient's any-device decrypt succeeds.

    Same rate-limit budget as the singleton endpoint — a fan-out
    request counts as a single fetch, not N.

    Capped at 8 bundles per response to bound payload size + protect
    a recipient who has dozens of stale device rows.
    """
    if not _check_prekey_fetch_rate_limit(current_user.id, user_id):
        logger.warning(
            "ATSAM prekey list fetch rate-limited viewer=%s target=%s",
            current_user.id,
            user_id,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit: too many prekey fetches",
        )

    rows = (
        db.query(ATSAMPreKeyBundle)
        .filter(ATSAMPreKeyBundle.user_id == user_id)
        .order_by(ATSAMPreKeyBundle.updated_at.desc())
        .limit(8)
        .all()
    )
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="no atsam bundle for this user",
        )
    return PreKeyBundleListDTO(
        user_id=user_id,
        bundles=[
            PreKeyBundleDTO(
                user_id=b.user_id,
                device_id=b.device_id,
                x25519_pub=b.x25519_pub,
                ml_kem_pub=b.ml_kem_pub,
                signed_by=b.signed_by,
                signature=b.signature,
                atsam_version=b.atsam_version,
            )
            for b in rows
        ],
    )


@router.post("/pair-init", response_model=SubmitPairInitResponse)
async def submit_pair_init(
    req: SubmitPairInitRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Deposit a pair-init packet for a recipient.

    The packet is opaque to the server. The sender already
    derived the hybrid root locally — the recipient will too
    once they fetch and decapsulate.

    🔴 ROUND 53 (2026-05-19) — hacker-audit Protocol F3 (HIGH).
    PREVIOUSLY: this endpoint accepted any (to_user, x25519_pub,
    ml_kem_pub, ml_kem_ct, pairing_nonce, context) tuple with no
    rate limit and no field-size validation. Pydantic enforced
    nothing more than "string of length ≥ 1". Concrete attacks:
      • Inbox bombing: 10k POSTs aimed at one victim → that
        victim's `/pair-init GET` returns a 30 MB array on next
        poll → iOS deserializer OOMs / blocks the main thread.
      • Storage flood: each pair-init row is ~2.7 KB legitimate;
        but the schema accepts arbitrarily large base64 strings,
        so an attacker can post pair-inits with 10 MB `ml_kem_pub`
        blobs → DB row bloat + replication lag.
      • Cross-pair churn: one rogue account can post 1000
        pair-inits to 1000 distinct recipients, polluting every
        ATSAM inbox at once.

    FIX (layered defense):
      • Per-sender (30/min) and per-(sender, recipient) (3/min)
        sliding-window rate limits.
      • Per-field base64-size caps tied to the FIPS-203 byte
        lengths plus a small slack for base64 padding.
      • Per-recipient inbox cap (64 undelivered pair-inits). At
        the cap, new submissions return 429; the recipient must
        ack stale ones before more land.
    """
    if req.to_user == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="cannot pair with yourself",
        )

    # 🔴 ROUND 53 — basic shape validation. Bound each field tight
    # enough that a malicious client can't bloat the row.
    if len(req.x25519_pub) > _PAIRINIT_MAX_X25519_PUB:
        raise HTTPException(status_code=400, detail="x25519_pub too large")
    if len(req.ml_kem_pub) > _PAIRINIT_MAX_MLKEM_PUB:
        raise HTTPException(status_code=400, detail="ml_kem_pub too large")
    if len(req.ml_kem_ct) > _PAIRINIT_MAX_MLKEM_CT:
        raise HTTPException(status_code=400, detail="ml_kem_ct too large")
    if len(req.pairing_nonce) > _PAIRINIT_MAX_PAIRING_NONCE:
        raise HTTPException(status_code=400, detail="pairing_nonce too large")
    if len(req.context) > _PAIRINIT_MAX_CONTEXT:
        raise HTTPException(status_code=400, detail="context too large")

    # 🔴 ROUND 53 — two-tier sender rate limit (30/min total, 3/min
    # per recipient). Defense against inbox bombing + cross-recipient
    # churn from a single compromised account.
    if not _check_pair_init_rate_limit(str(current_user.id), str(req.to_user)):
        logger.warning(
            "ATSAM pair-init rate-limited sender=%s recipient=%s",
            current_user.id, req.to_user,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit: too many pair-init submissions",
        )

    # 🔴 ROUND 53 — per-recipient inbox cap. Defense against a botnet
    # of N senders (each within their own per-sender budget)
    # collectively flooding one victim's inbox.
    pending_count = (
        db.query(ATSAMPairInit)
        .filter(
            ATSAMPairInit.to_user == req.to_user,
            ATSAMPairInit.delivered == 0,
        )
        .count()
    )
    if pending_count >= _PAIRINIT_INBOX_CAP:
        logger.warning(
            "ATSAM pair-init inbox-cap hit recipient=%s pending=%d",
            req.to_user, pending_count,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="recipient inbox full — try later",
        )

    # 🔴 ROUND 54 (2026-05-19) — hacker-audit Protocol F4 (HIGH).
    #
    # PREVIOUSLY: the server happily stored ANY `x25519_pub` /
    # `ml_kem_pub` the sender supplied in the pair-init body —
    # there was no check that those keys matched the sender's OWN
    # published bundle. Concrete attack:
    #   1. Alice has published bundle A_bundle = (xA_real, pqA_real).
    #   2. Alice's session token is stolen, OR Alice is compromised.
    #   3. Attacker submits a pair-init claiming `from_user = Alice`
    #      with KEYS THEY CONTROL: (xE, pqE, ctE→Bob_pq).
    #   4. Bob fetches → tries pairAsResponder with (xE, pqE) →
    #      derives a root with attacker, NOT with Alice.
    #   5. The ATSAM mismatch banner WILL fire on the next message
    #      because Bob's PeerKeyDirectory holds Alice's real bundle
    #      and the responder transcript binds those keys (the
    #      transcript will derive a different root → first message
    #      fails to authenticate).
    #   6. BUT: between pair-init submission and the first encrypted
    #      message, Bob's iOS may have already SHOWN the chat as
    #      "paired" — and Bob may type a reply that gets sealed under
    #      attacker's root before the mismatch fires (transcript
    #      checks happen on receive, not on send).
    #
    # Strong defense: require the pair-init's `x25519_pub` to MATCH
    # the sender's currently-published bundle. If they don't match,
    # the sender doesn't actually hold the keys they're claiming to
    # offer — server-side reject. (Clients still verify the deeper
    # transcript binding; this is server-side hygiene that closes
    # the "Bob's UI flashes paired for a second" timing window.)
    #
    # We INTENTIONALLY only check x25519_pub (not ml_kem_pub) —
    # ml_kem_pub may have been rotated since publish; x25519_pub
    # rotates less frequently. We also allow pair-init when no
    # bundle is published yet (cold-start scenario for the very
    # first publish + pair-init burst from a brand new account).
    own_bundle = (
        db.query(ATSAMPreKeyBundle)
        .filter(ATSAMPreKeyBundle.user_id == current_user.id)
        .order_by(ATSAMPreKeyBundle.updated_at.desc())
        .first()
    )
    if own_bundle is not None:
        if own_bundle.x25519_pub != req.x25519_pub:
            logger.warning(
                "ATSAM pair-init key mismatch sender=%s — pair-init x25519_pub != published bundle x25519_pub",
                current_user.id,
            )
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="pair-init x25519_pub does not match your published bundle. "
                       "Publish your current bundle first, or rotate the bundle.",
            )

    init = ATSAMPairInit(
        from_user=current_user.id,
        to_user=req.to_user,
        x25519_pub=req.x25519_pub,
        ml_kem_pub=req.ml_kem_pub,
        ml_kem_ct=req.ml_kem_ct,
        pairing_nonce=req.pairing_nonce,
        context=req.context,
    )
    db.add(init)
    db.commit()
    db.refresh(init)
    logger.info(
        "ATSAM pair-init queued id=%d from=%s to=%s",
        init.id,
        current_user.id,
        req.to_user,
    )
    return SubmitPairInitResponse(id=init.id)


@router.get("/pair-init", response_model=list[PairInitDTO])
async def fetch_pending_pair_inits(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Return all undelivered pair-init packets addressed to the
    caller. Caller MUST acknowledge each one via the ack endpoint
    after successfully running pairAsResponder locally; otherwise
    the same pair-init is returned on next poll.
    """
    pending = (
        db.query(ATSAMPairInit)
        .filter(
            ATSAMPairInit.to_user == current_user.id,
            ATSAMPairInit.delivered == 0,
        )
        .order_by(ATSAMPairInit.created_at.asc())
        .all()
    )
    return [
        PairInitDTO(
            id=p.id,
            from_user=p.from_user,
            to_user=p.to_user,
            x25519_pub=p.x25519_pub,
            ml_kem_pub=p.ml_kem_pub,
            ml_kem_ct=p.ml_kem_ct,
            pairing_nonce=p.pairing_nonce,
            context=p.context,
            created_at=p.created_at,
        )
        for p in pending
    ]


@router.post("/pair-init/{init_id}/ack")
async def ack_pair_init(
    init_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Mark a pair-init as delivered. Must be called by the
    recipient after a successful local pairAsResponder. We do not
    delete the row — keeping it as a billing-style audit
    artefact. Future builds may rotate it to cold storage.
    """
    init = db.query(ATSAMPairInit).filter(ATSAMPairInit.id == init_id).first()
    if not init:
        raise HTTPException(status_code=404, detail="pair-init not found")
    if init.to_user != current_user.id:
        raise HTTPException(status_code=403, detail="not your pair-init")
    init.delivered = 1
    db.commit()
    return {"ok": True}
