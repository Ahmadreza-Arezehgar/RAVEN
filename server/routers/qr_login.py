"""
QR-Code Login — desktop-linking via mobile-scan flow.

Pattern: WhatsApp Web. Desktop initiates a session, displays a QR code, and
polls for completion. Mobile (already authenticated) scans the QR, sends a
signed `/scan`, then a signed `/approve`. Server then issues access +
refresh tokens that the desktop receives on its next poll.

State machine:

    pending → scanned → approved   (happy path)
            ↘ denied
            ↘ expired (TTL hit)

Single-use guarantee: the first successful poll after `approved` flips
`consumed_at`; any subsequent poll returns `expired`.
"""

import base64
import hashlib
import secrets
import time
import uuid
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel
from sqlalchemy import Column, DateTime, String
from sqlalchemy.orm import Session

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from auth import create_access_token, create_db_refresh_token
from database import Base, get_db
from models import User
from routers.linked_devices import LinkedDevice
from routers.users import get_current_user

router = APIRouter(prefix="/api/auth/qr-login", tags=["qr_login"])


# Session lives for 2 minutes from creation.
SESSION_TTL_SECONDS = 120

# Mobile-side timestamps must be within this skew of server time.
MAX_TIMESTAMP_SKEW_SECONDS = 30


# ────────────────────────────────────────────────────────────────────────
# DB Model
# ────────────────────────────────────────────────────────────────────────


class QrLoginSession(Base):
    """One row per `/init` call. Hot rows live ≤ 120 s; sweep job (or
    natural traffic) eventually marks stale rows as expired."""

    __tablename__ = "qr_login_sessions"

    id = Column(String, primary_key=True)
    nonce = Column(String, nullable=False)
    status = Column(String, nullable=False, default="pending", index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    expires_at = Column(DateTime, nullable=False)
    consumed_at = Column(DateTime, nullable=True)
    requester_ip = Column(String, nullable=True)
    mobile_user_id = Column(String, nullable=True, index=True)
    mobile_device_id = Column(String, nullable=True)


# ────────────────────────────────────────────────────────────────────────
# Schemas
# ────────────────────────────────────────────────────────────────────────


class InitResponse(BaseModel):
    sessionId: str
    nonce: str
    expiresAt: datetime


class PollResponse(BaseModel):
    status: str
    token: Optional[str] = None
    refreshToken: Optional[str] = None
    userId: Optional[str] = None
    username: Optional[str] = None


class ScanRequest(BaseModel):
    sessionId: str
    nonce: str
    timestamp: int  # unix seconds
    deviceFingerprint: str
    signature: str  # base64; signs `v1|sid|n|deviceFp|ts`


class ScanResponse(BaseModel):
    status: str
    requesterIp: Optional[str] = None
    expiresAt: datetime


class ApproveRequest(BaseModel):
    sessionId: str
    timestamp: int
    signature: str  # base64; signs `sid|approved|ts`
    desktopDeviceName: str
    desktopDeviceModel: Optional[str] = None
    desktopDeviceOs: Optional[str] = None


class ApproveResponse(BaseModel):
    status: str


class DenyRequest(BaseModel):
    sessionId: str


# ────────────────────────────────────────────────────────────────────────
# Internals
# ────────────────────────────────────────────────────────────────────────


def _verify_rsa_signature(message: str, signature_b64: str, public_key_pem: str) -> bool:
    """Verify Flutter `CryptoService.signMessage` output.

    Flutter pre-hashes (sha256(message)) and passes the digest to
    `pointycastle.RSASigner`, which itself sha256-hashes the input. Effectively
    the signed payload is sha256(sha256(message)). To match, we feed the
    pre-hash to `cryptography.verify` and let it sha256-hash again.
    """
    try:
        prehash = hashlib.sha256(message.encode("utf-8")).digest()
        sig = base64.b64decode(signature_b64, validate=True)
        public_key = serialization.load_pem_public_key(public_key_pem.encode("utf-8"))
        public_key.verify(sig, prehash, padding.PKCS1v15(), hashes.SHA256())
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


def _verify_signature(message: str, signature_b64: str, public_key_str: str) -> bool:
    """Verify a signature over `message` using the user's stored public key.

    Two key formats are supported transparently:

    1. **PEM-encoded RSA** (Flutter legacy) — `_verify_rsa_signature` above.
       Used by mobile clients that registered before iOS native.
    2. **Base64-encoded raw Ed25519** (iOS native) — 32-byte raw public key
       (`Curve25519.Signing.PublicKey.rawRepresentation`). Signature is the
       64-byte raw Ed25519 signature, also base64-encoded. The signed payload
       is the raw UTF-8 bytes of `message` (no double-hashing — Ed25519
       hashes internally with SHA-512 as part of the signing primitive).

    Returns True iff verification succeeds with EITHER format. Order of
    attempts is RSA first (cheap PEM-header check fails fast on Ed25519
    keys) then Ed25519. Wrong-format key + bad signature both return False
    without leaking which path was tried.
    """
    # Path 1: RSA PEM
    if "BEGIN PUBLIC KEY" in (public_key_str or ""):
        if _verify_rsa_signature(message, signature_b64, public_key_str):
            return True

    # Path 2: raw Ed25519 (iOS native — what `DeviceIdentityService.sign`
    # produces and `publicKeyBase64` exports).
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        raw_pub = base64.b64decode(public_key_str, validate=True)
        if len(raw_pub) != 32:
            return False
        sig = base64.b64decode(signature_b64, validate=True)
        if len(sig) != 64:
            return False
        Ed25519PublicKey.from_public_bytes(raw_pub).verify(sig, message.encode("utf-8"))
        return True
    except (InvalidSignature, ValueError, TypeError, ImportError):
        return False


def _maybe_expire(session: QrLoginSession) -> bool:
    """If TTL has passed and status is still pending/scanned, flip to expired.
    Returns True when the row was newly expired (caller must commit)."""
    if session.status in ("expired", "approved", "denied"):
        return False
    if datetime.utcnow() >= session.expires_at:
        session.status = "expired"
        return True
    return False


def _check_timestamp(ts: int) -> bool:
    # Use `time.time()` (Unix epoch, always UTC) — `datetime.utcnow().timestamp()`
    # treats the naive datetime as local time and applies the local→UTC offset.
    return abs(time.time() - ts) <= MAX_TIMESTAMP_SKEW_SECONDS


def _get_session_for_mobile(
    db: Session, session_id: str, expected_statuses: tuple[str, ...]
) -> QrLoginSession:
    session = db.query(QrLoginSession).filter(QrLoginSession.id == session_id).first()
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if _maybe_expire(session):
        db.commit()
        raise HTTPException(status_code=410, detail="Session expired")
    if session.status not in expected_statuses:
        raise HTTPException(
            status_code=409,
            detail=f"Session is {session.status!r}, expected one of {expected_statuses}",
        )
    return session


# ────────────────────────────────────────────────────────────────────────
# Endpoints
# ────────────────────────────────────────────────────────────────────────


@router.post("/init", response_model=InitResponse)
def init_session(request: Request, db: Session = Depends(get_db)):
    """Desktop calls this to start a login flow. Returns the session id and
    nonce that the desktop encodes into a QR for the mobile app to scan."""
    now = datetime.utcnow()
    row = QrLoginSession(
        id=str(uuid.uuid4()),
        nonce=secrets.token_urlsafe(32),
        status="pending",
        created_at=now,
        expires_at=now + timedelta(seconds=SESSION_TTL_SECONDS),
        requester_ip=request.client.host if request.client else None,
    )
    db.add(row)
    db.commit()
    return InitResponse(sessionId=row.id, nonce=row.nonce, expiresAt=row.expires_at)


@router.get("/poll/{session_id}", response_model=PollResponse)
def poll_session(
    session_id: str,
    nonce: str = Query(...),
    db: Session = Depends(get_db),
):
    """Desktop polls every 2 s. The nonce gates the polling identity — even
    a third party who saw the QR fleetingly cannot poll without the nonce."""
    session = db.query(QrLoginSession).filter(QrLoginSession.id == session_id).first()
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if not secrets.compare_digest(session.nonce, nonce):
        raise HTTPException(status_code=403, detail="Bad nonce")

    if _maybe_expire(session):
        db.commit()

    if session.status in ("pending", "scanned", "denied", "expired"):
        return PollResponse(status=session.status)

    # status == "approved"
    if session.consumed_at is not None:
        # Already consumed by an earlier poll. From the desktop's perspective
        # this means a stale poll on a session that's already done its job.
        return PollResponse(status="expired")

    # 🔴 ROUND 49 (2026-05-19) — hacker-audit Server F13 (HIGH).
    #
    # PREVIOUSLY: this endpoint read `session.consumed_at IS NULL`,
    # then minted access+refresh tokens, then wrote
    # `session.consumed_at = utcnow()` and committed. Between the
    # check and the write, a CONCURRENT poll with the same
    # session_id+nonce would also see `consumed_at IS NULL` and ALSO
    # mint a fresh access/refresh pair. Both desktops then walk away
    # with valid tokens — one of them attacker-controlled if they
    # captured the QR contents (shoulder-surf, screen-share leak,
    # surveillance camera). Same-instance Postgres serializes the
    # commits, but the iat-equal access tokens were already in the
    # response bodies. Same desktop client polling twice fast (no
    # malice) also doubled the refresh-token rows in `oauth_refresh_
    # tokens`, polluting the table.
    #
    # FIX: use a single UPDATE … WHERE consumed_at IS NULL with
    # rowcount=1 as the atomic claim primitive. Tokens are minted
    # ONLY when the UPDATE wins the race. The losing poller gets the
    # same `expired` response as a stale poll.
    claim_result = db.execute(
        QrLoginSession.__table__.update()
        .where(QrLoginSession.id == session_id)
        .where(QrLoginSession.consumed_at.is_(None))
        .where(QrLoginSession.status == "approved")
        .values(consumed_at=datetime.utcnow())
    )
    if claim_result.rowcount != 1:
        # A concurrent poller already won the claim. Either the
        # desktop client raced itself, or someone with the nonce
        # tried to piggyback. Either way: no second token.
        db.commit()
        return PollResponse(status="expired")
    db.commit()

    # We now hold an exclusive claim — safe to mint tokens.
    user = db.query(User).filter(User.id == session.mobile_user_id).first()
    if user is None:
        # Shouldn't happen — mobile_user_id was set from a verified JWT.
        raise HTTPException(status_code=500, detail="User vanished")

    access = create_access_token({"sub": user.id})
    refresh = create_db_refresh_token(
        db,
        user_id=user.id,
        device_id=session.mobile_device_id,
        device_name=f"desktop_qr_login:{user.id[:8]}",
        ip_address=session.requester_ip,
    )

    return PollResponse(
        status="approved",
        token=access,
        refreshToken=refresh,
        userId=user.id,
        username=user.username,
    )


@router.post("/scan", response_model=ScanResponse)
def scan_session(
    body: ScanRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Mobile flips `pending` → `scanned`. Body must include a signature
    over `v1|sid|n|deviceFp|ts` produced by the mobile's RSA private key
    from `lib/services/device_identity_service.dart`."""
    if not _check_timestamp(body.timestamp):
        raise HTTPException(status_code=400, detail="Timestamp out of window")

    session = _get_session_for_mobile(db, body.sessionId, ("pending",))

    if not secrets.compare_digest(session.nonce, body.nonce):
        raise HTTPException(status_code=403, detail="Bad nonce")

    if not current_user.public_key:
        raise HTTPException(status_code=400, detail="User has no registered public key")

    payload = f"v1|{body.sessionId}|{body.nonce}|{body.deviceFingerprint}|{body.timestamp}"
    if not _verify_signature(payload, body.signature, current_user.public_key):
        raise HTTPException(status_code=401, detail="Bad signature")

    session.status = "scanned"
    session.mobile_user_id = current_user.id
    db.commit()

    return ScanResponse(
        status="scanned",
        requesterIp=session.requester_ip,
        expiresAt=session.expires_at,
    )


@router.post("/approve", response_model=ApproveResponse)
def approve_session(
    body: ApproveRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Mobile flips `scanned` → `approved`. Server upserts a `LinkedDevice`
    row for the desktop and prepares tokens (issued on the desktop's next
    poll). Same user who scanned must approve."""
    if not _check_timestamp(body.timestamp):
        raise HTTPException(status_code=400, detail="Timestamp out of window")

    session = _get_session_for_mobile(db, body.sessionId, ("scanned",))

    if session.mobile_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Different user than scanner")

    if not current_user.public_key:
        raise HTTPException(status_code=400, detail="User has no registered public key")

    payload = f"{body.sessionId}|approved|{body.timestamp}"
    if not _verify_signature(payload, body.signature, current_user.public_key):
        raise HTTPException(status_code=401, detail="Bad signature")

    # Upsert LinkedDevice for the desktop, keyed on (user, device_name).
    desktop_device_name = body.desktopDeviceName.strip()
    if not desktop_device_name:
        desktop_device_name = body.desktopDeviceModel or "Unknown desktop"

    device = db.query(LinkedDevice).filter(
        LinkedDevice.user_id == current_user.id,
        LinkedDevice.device_name == desktop_device_name,
        LinkedDevice.revoked_at.is_(None),
    ).first()

    if device is None:
        device = LinkedDevice(
            id=str(uuid.uuid4()),
            user_id=current_user.id,
            device_name=desktop_device_name,
            device_model=body.desktopDeviceModel,
            device_os=body.desktopDeviceOs,
            ip_first=session.requester_ip,
        )
        db.add(device)
    else:
        device.last_seen_at = datetime.utcnow()
        if body.desktopDeviceModel:
            device.device_model = body.desktopDeviceModel
        if body.desktopDeviceOs:
            device.device_os = body.desktopDeviceOs

    db.flush()

    session.status = "approved"
    session.mobile_device_id = device.id
    db.commit()

    return ApproveResponse(status="approved")


@router.post("/deny")
def deny_session(
    body: DenyRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Mobile rejects the desktop login. Idempotent — denying a denied
    session is a no-op."""
    session = db.query(QrLoginSession).filter(QrLoginSession.id == body.sessionId).first()
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")

    # Don't reveal info to non-scanner: only the user who scanned (or no one
    # has scanned yet) can deny. If status is `pending`, we still allow the
    # caller to deny — it short-circuits a session before scan, e.g. if the
    # user opened the camera but bailed.
    if session.mobile_user_id and session.mobile_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Different user than scanner")

    if session.status in ("approved",):
        raise HTTPException(status_code=409, detail="Already approved")

    if session.status not in ("denied",):
        session.status = "denied"
        db.commit()

    return {"status": "denied"}
