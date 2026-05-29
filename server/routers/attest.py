"""
🔴 v1.8 (2026-05-21) — feature #3: App Attest device enrolment.

Endpoints for registering an iOS device's Apple App Attest key:
  POST /api/attest/challenge  — issue a single-use challenge nonce.
  POST /api/attest/enroll     — verify the attestation, store the key.
  GET  /api/attest/status     — has the caller enrolled a device?

Verification lives in services/app_attest.py. The enrolled key lets
future requests be proven genuine via App Attest assertions (a
follow-up). Enrolment alone is already a strong device-integrity
signal and is purely additive — it has zero impact on the mesh
relay, the bridge, or non-iOS clients, none of which call these
endpoints.
"""
import base64
import os
import secrets
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import get_db
from middleware.rate_limit import rate_limiter
from models import AttestChallenge, DeviceAttestation, User
from routers.users import get_current_user
from services.app_attest import AttestationError, verify_attestation

router = APIRouter(prefix="/api/attest", tags=["attest"])

# A challenge is single-use and short-lived.
_CHALLENGE_TTL_SECONDS = 300


def _app_team_id() -> str:
    return os.getenv("APNS_TEAM_ID", "72QQ5Q324C")


def _app_bundle_id() -> str:
    return os.getenv("APNS_BUNDLE_ID", "app.raven.ios")


def _allow_development() -> bool:
    return os.getenv("APP_ATTEST_ALLOW_DEV", "true").lower() != "false"


# ─────────────────────────────────────────────────────────────────────
# DTOs
# ─────────────────────────────────────────────────────────────────────

class ChallengeResponse(BaseModel):
    challenge: str            # base64
    expires_at: datetime


class EnrollRequest(BaseModel):
    key_id: str               # base64 — the App Attest key id
    attestation: str          # base64 — the CBOR attestation object
    challenge: str            # base64 — echo of the issued challenge


class EnrollResponse(BaseModel):
    enrolled: bool
    key_id: str
    environment: str


class AttestStatusResponse(BaseModel):
    enrolled: bool
    environment: Optional[str] = None
    key_id: Optional[str] = None


# ─────────────────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────────────────

@router.post("/challenge", response_model=ChallengeResponse)
def request_challenge(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Issue a fresh single-use App Attest challenge for the caller."""
    # 🔴 hacker-audit — rate-limit + prune so a client cannot grow the
    # attest_challenges table without bound by hammering this endpoint.
    rate_limiter.check_rate_limit(
        identifier=f"attest-challenge:{current_user.id}",
        max_attempts=30,
        window_minutes=1,
        lockout_minutes=5,
    )
    now = datetime.utcnow()
    # Drop this caller's already-expired challenges (cheap, scoped GC).
    db.query(AttestChallenge).filter(
        AttestChallenge.user_id == current_user.id,
        AttestChallenge.expires_at < now,
    ).delete(synchronize_session=False)

    challenge_b64 = base64.b64encode(secrets.token_bytes(32)).decode()
    expires_at = now + timedelta(seconds=_CHALLENGE_TTL_SECONDS)
    db.add(AttestChallenge(
        user_id=current_user.id,
        challenge=challenge_b64,
        expires_at=expires_at,
    ))
    db.commit()
    return ChallengeResponse(challenge=challenge_b64, expires_at=expires_at)


@router.post("/enroll", response_model=EnrollResponse)
def enroll(
    req: EnrollRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Verify an Apple App Attest attestation and enrol the device key."""
    # ---- decode inputs ----
    try:
        key_id = base64.b64decode(req.key_id)
        attestation = base64.b64decode(req.attestation)
        challenge_raw = base64.b64decode(req.challenge)
    except Exception:
        raise HTTPException(status_code=400, detail="Malformed base64 in request")
    if not key_id or not attestation or not challenge_raw:
        raise HTTPException(
            status_code=400,
            detail="key_id, attestation and challenge are all required",
        )

    # ---- consume the challenge (single-use, the caller's, unexpired) ----
    row = db.query(AttestChallenge).filter(
        AttestChallenge.user_id == current_user.id,
        AttestChallenge.challenge == req.challenge,
    ).first()
    if row is None:
        raise HTTPException(status_code=400, detail="Unknown challenge")
    if row.consumed:
        raise HTTPException(status_code=400, detail="Challenge already used")
    if row.expires_at < datetime.utcnow():
        raise HTTPException(status_code=400, detail="Challenge expired")
    # Consume BEFORE verifying — a failed attestation must not leave the
    # challenge reusable (no brute-forcing one challenge).
    row.consumed = True
    db.commit()

    # ---- verify the attestation (fails closed) ----
    try:
        verified = verify_attestation(
            key_id=key_id,
            attestation=attestation,
            challenge=challenge_raw,
            team_id=_app_team_id(),
            bundle_id=_app_bundle_id(),
            allow_development=_allow_development(),
        )
    except AttestationError as e:
        raise HTTPException(status_code=400, detail=f"Attestation rejected: {e}")

    # ---- store / refresh the device attestation ----
    receipt_b64 = (
        base64.b64encode(verified.receipt).decode() if verified.receipt else None
    )
    existing = db.query(DeviceAttestation).filter(
        DeviceAttestation.key_id == req.key_id,
    ).first()
    if existing is not None:
        # A key id is the SHA-256 of a Secure-Enclave public key — it
        # cannot legitimately belong to two accounts.
        if existing.user_id != current_user.id:
            raise HTTPException(
                status_code=409,
                detail="This device key is already enrolled to another account",
            )
        existing.public_key = verified.public_key_pem
        existing.environment = verified.environment
        existing.sign_count = verified.sign_count
        existing.receipt = receipt_b64
        existing.last_verified_at = datetime.utcnow()
    else:
        db.add(DeviceAttestation(
            user_id=current_user.id,
            key_id=req.key_id,
            public_key=verified.public_key_pem,
            environment=verified.environment,
            sign_count=verified.sign_count,
            receipt=receipt_b64,
            last_verified_at=datetime.utcnow(),
        ))
    db.commit()

    return EnrollResponse(
        enrolled=True, key_id=req.key_id, environment=verified.environment
    )


@router.get("/status", response_model=AttestStatusResponse)
def get_status(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Whether the caller has an enrolled App Attest device key."""
    row = db.query(DeviceAttestation).filter(
        DeviceAttestation.user_id == current_user.id,
    ).order_by(DeviceAttestation.last_verified_at.desc()).first()
    if row is None:
        return AttestStatusResponse(enrolled=False)
    return AttestStatusResponse(
        enrolled=True, environment=row.environment, key_id=row.key_id
    )
