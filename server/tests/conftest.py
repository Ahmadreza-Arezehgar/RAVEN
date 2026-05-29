"""Test fixtures shared across the QR-login (and future) tests.

Each test gets a fresh SQLite-in-memory DB and a TestClient with the
production `get_db` dependency overridden. We avoid touching the real
`encrypted.db` so dev data is never disturbed.
"""

import base64
import hashlib
import os
import sys
import uuid
from typing import Iterator

# Make `server/` importable when pytest is invoked from repo root or server/.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)

# Force dev mode before importing anything that reads ENVIRONMENT/JWT_SECRET.
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool


@pytest.fixture
def test_db():
    """Fresh in-memory SQLite for each test. Yields a sessionmaker bound to
    the test engine; tests can open additional sessions if they need to."""
    from database import Base

    # Force-import every model module so all tables are registered on Base.
    import models  # noqa: F401
    from routers.linked_devices import LinkedDevice  # noqa: F401
    from routers.qr_login import QrLoginSession  # noqa: F401

    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    TestSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    yield TestSession
    engine.dispose()


@pytest.fixture
def client(test_db):
    """Minimal FastAPI app with ONLY the qr_login router.

    We deliberately avoid importing `main.app` because the production app
    pulls in heavyweight deps (google-cloud, livekit, redis, …) that are
    out of scope for unit tests of this router. The qr_login router only
    needs `get_db`, `User`, `LinkedDevice`, and `auth.py`'s token helpers,
    all of which import cleanly with the test deps in `requirements.txt`.
    """
    from fastapi import FastAPI

    from database import get_db
    from routers import qr_login

    def override_get_db():
        db = test_db()
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app = FastAPI()
    app.include_router(qr_login.router)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        # Stash on the client so tests can reach into the override if needed.
        c._test_db_factory = test_db  # type: ignore[attr-defined]
        yield c


@pytest.fixture
def rsa_keypair():
    """Generate an RSA-2048 keypair for signing test payloads. Returns
    (private_key, public_key_pem_str)."""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("utf-8")
    return private_key, public_pem


def flutter_sign(private_key, message: str) -> str:
    """Reproduce `lib/services/crypto_service.dart#signMessage`.

    Flutter pre-hashes the message with SHA-256 and feeds the digest into
    pointycastle's RSASigner, which itself SHA-256-hashes its input. So the
    signed payload is sha256(sha256(message)). We replicate that by passing
    the pre-hash to `cryptography.sign(..., SHA256())`.
    """
    prehash = hashlib.sha256(message.encode("utf-8")).digest()
    sig = private_key.sign(prehash, padding.PKCS1v15(), hashes.SHA256())
    return base64.b64encode(sig).decode("ascii")


@pytest.fixture
def make_user(test_db, rsa_keypair):
    """Factory: create a User row with a known RSA keypair and return
    (user_id, private_key, jwt_token)."""
    private_key, public_pem = rsa_keypair

    def _make(username: str = "alice"):
        from auth import create_access_token
        from models import User

        db = test_db()
        try:
            user = User(
                id=str(uuid.uuid4()),
                username=username,
                public_key=public_pem,
            )
            db.add(user)
            db.commit()
            uid = user.id
        finally:
            db.close()

        token = create_access_token({"sub": uid})
        return uid, private_key, token

    return _make
