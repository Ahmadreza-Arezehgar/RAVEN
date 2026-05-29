"""
OPAQUE PAKE Router — Phase 2 of the auth-security roadmap.

⚠️  STATUS — SCAFFOLD ONLY  ⚠️

This module defines the OPAQUE endpoints, the request/response shape,
and the SQL schema for credential envelopes. The cryptographic OPRF +
AKE math is NOT implemented here — wire `opaque-ke` (Rust, via PyO3)
or `python-opaque` into the marked spots before flipping the
``OPAQUE_ENABLED`` flag.

When this is wired up, the auth flow becomes:

    Client                                        Server
    ──────                                        ──────
    register(username, password)
        │
        │ 1. POST /api/auth/opaque/register/start
        │    { username, blinded_message }
        │   ────────────────────────────────────────────►
        │                                               │
        │                       (server runs OPRF eval)│
        │   ◄────────────────────────────────────────────
        │    { evaluation, server_identity }
        │
        │ 2. POST /api/auth/opaque/register/finish
        │    { username, envelope, masking_key,
        │      client_identity }
        │   ────────────────────────────────────────────►
        │                                               │
        │           (server stores envelope row)         │
        │   ◄────────────────────────────────────────────
        │    204
        │
        │ done — server stores opaque blob, never the password

    login(username, password)
        │
        │ 1. POST /api/auth/opaque/login/start
        │    { username, ke1 }
        │   ────────────────────────────────────────────►
        │                                               │
        │      (server reads envelope, runs KE2)         │
        │   ◄────────────────────────────────────────────
        │    { ke2 }
        │
        │ 2. POST /api/auth/opaque/login/finish
        │    { username, ke3 }
        │   ────────────────────────────────────────────►
        │                                               │
        │       (server validates KE3, mints JWT)        │
        │   ◄────────────────────────────────────────────
        │    { access_token_wrapped, refresh_token_wrapped, user_id }
        │
        │ done — JWT is wrapped under the OPAQUE-derived
        │        session key so a network observer can't
        │        lift it from the response body
"""

import os
import logging
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import Column, String, LargeBinary, Float, ForeignKey
from sqlalchemy.orm import Session
from pydantic import BaseModel
from datetime import datetime

from database import get_db, Base
from models import User

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/auth/opaque", tags=["auth-opaque"])

# Master flag — flip to True only when a real OPAQUE implementation
# is wired in. Until then every endpoint returns 501 Not Implemented.
OPAQUE_ENABLED = os.getenv("OPAQUE_ENABLED", "0") == "1"


# ──────────────────────────────────────────────────────────────────────────
# DB model
# ──────────────────────────────────────────────────────────────────────────

class OPAQUEEnvelope(Base):
    """One credential envelope per user. Created by register, consumed
    on every login. All fields are opaque blobs from the OPAQUE library
    — the server never sees plaintext password material."""
    __tablename__ = "opaque_envelopes"

    user_id = Column(String, ForeignKey("users.id"), primary_key=True)
    envelope = Column(LargeBinary, nullable=False)
    masking_key = Column(LargeBinary, nullable=False)
    client_identity = Column(LargeBinary, nullable=False)
    created_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())
    updated_at = Column(Float, nullable=False, default=lambda: datetime.utcnow().timestamp())


# ──────────────────────────────────────────────────────────────────────────
# Pydantic schemas
# ──────────────────────────────────────────────────────────────────────────

class RegisterStartRequest(BaseModel):
    username: str
    blinded_message: bytes


class RegisterStartResponse(BaseModel):
    evaluation: bytes
    server_identity: bytes


class RegisterFinishRequest(BaseModel):
    username: str
    envelope: bytes
    masking_key: bytes
    client_identity: bytes


class LoginStartRequest(BaseModel):
    username: str
    ke1: bytes


class LoginStartResponse(BaseModel):
    ke2: bytes


class LoginFinishRequest(BaseModel):
    username: str
    ke3: bytes


class LoginFinishResponse(BaseModel):
    access_token_wrapped: bytes
    refresh_token_wrapped: bytes
    user_id: str


# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────

def _ensure_enabled() -> None:
    if not OPAQUE_ENABLED:
        # 501 explicitly — the iOS client is expected to fall back
        # to the legacy /api/auth/login path when it sees this code.
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail="OPAQUE PAKE not yet enabled on this server. "
                   "Wire opaque-ke (or libopaque/python-opaque) and "
                   "set OPAQUE_ENABLED=1 to activate.",
        )


# ──────────────────────────────────────────────────────────────────────────
# Endpoints — all stubbed
# ──────────────────────────────────────────────────────────────────────────

@router.post("/register/start", response_model=RegisterStartResponse)
def register_start(body: RegisterStartRequest, db: Session = Depends(get_db)):
    """Phase 1 of OPAQUE registration. Server runs the OPRF
    evaluation and returns it along with the server's static identity.

    TODO(opaque): replace with `opaque_ke::ServerRegistration::start`.
    """
    _ensure_enabled()
    raise NotImplementedError  # pragma: no cover


@router.post("/register/finish", status_code=status.HTTP_204_NO_CONTENT)
def register_finish(body: RegisterFinishRequest, db: Session = Depends(get_db)):
    """Phase 2 of OPAQUE registration. Stores the envelope produced
    by the client. Idempotent on (user_id) — a second call replaces
    the prior envelope (used during password change).

    TODO(opaque): validate envelope shape via opaque-ke before INSERT.
    """
    _ensure_enabled()
    raise NotImplementedError  # pragma: no cover


@router.post("/login/start", response_model=LoginStartResponse)
def login_start(body: LoginStartRequest, db: Session = Depends(get_db)):
    """Phase 1 of OPAQUE login. Looks up the envelope and produces KE2.

    TODO(opaque): replace with `opaque_ke::ServerLogin::start`.
    """
    _ensure_enabled()
    raise NotImplementedError  # pragma: no cover


@router.post("/login/finish", response_model=LoginFinishResponse)
def login_finish(body: LoginFinishRequest, db: Session = Depends(get_db)):
    """Phase 2 of OPAQUE login. Validates KE3, derives the session
    key, mints a JWT, and wraps it under the session key before
    returning. Same JWT shape as /api/auth/login so downstream code
    is unchanged.

    TODO(opaque):
      • opaque_ke::ServerLogin::finish to derive the session key.
      • AEAD-wrap the existing create_access_token() / create_refresh_token()
        outputs under HKDF(session_key, "RAVEN_AUTH_TOKEN").
    """
    _ensure_enabled()
    raise NotImplementedError  # pragma: no cover


@router.get("/health")
def opaque_health():
    """Cheap probe so the iOS client can decide on cold start whether
    the OPAQUE path is available without paying for a full handshake."""
    return {"enabled": OPAQUE_ENABLED}
