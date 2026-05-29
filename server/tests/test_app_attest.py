"""Tests for v1.8 feature #3 — App Attest device enrolment.

App Attest verification needs a certificate chain rooted at Apple's
App Attest Root CA, which can only be produced by a real device. To
exercise the FULL verification path here, these tests build a
*synthetic* attestation: a self-contained test root + intermediate CA
and a leaf "device" cert carrying a correctly-derived nonce — the
exact structure Apple produces, just rooted at a test CA. The verifier
takes the root as a parameter (`root_ca_pem`), so the happy path runs
against the test root and the negative paths prove real rejection.
"""

import base64
import hashlib
import os
import secrets
import sys
import uuid
from datetime import datetime, timedelta

import pytest

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

import cbor2  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.x509.oid import NameOID  # noqa: E402
from fastapi import HTTPException  # noqa: E402

import services.app_attest as app_attest  # noqa: E402
from services.app_attest import AttestationError, verify_attestation  # noqa: E402
from routers.attest import (  # noqa: E402
    EnrollRequest, enroll, get_status, request_challenge,
)
from models import AttestChallenge, DeviceAttestation, User  # noqa: E402

_TEAM = "72QQ5Q324C"
_BUNDLE = "app.raven.ios"
_NONCE_OID = "1.2.840.113635.100.8.2"
_AAGUID_DEV = b"appattestdevelop"
_AAGUID_PROD = b"appattest\x00\x00\x00\x00\x00\x00\x00"


# ─────────────────────────────────────────────────────────────────────
# Synthetic-attestation generator
# ─────────────────────────────────────────────────────────────────────

def _make_chain():
    """A self-contained test root + intermediate CA (both P-384)."""
    root_key = ec.generate_private_key(ec.SECP384R1())
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Attest Root")])
    now = datetime.utcnow()
    root_cert = (
        x509.CertificateBuilder()
        .subject_name(root_name).issuer_name(root_name)
        .public_key(root_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(root_key, hashes.SHA384())
    )
    inter_key = ec.generate_private_key(ec.SECP384R1())
    inter_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Attest CA")])
    inter_cert = (
        x509.CertificateBuilder()
        .subject_name(inter_name).issuer_name(root_name)
        .public_key(inter_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(root_key, hashes.SHA384())
    )
    return root_key, root_cert, inter_key, inter_cert


def _make_attestation(*, challenge, inter_key, inter_cert,
                      team_id=_TEAM, bundle_id=_BUNDLE,
                      aaguid=_AAGUID_DEV, sign_count=0,
                      nonce_challenge=None, cred_id_override=None):
    """Build a synthetic App Attest attestation object. Returns
    (key_id_bytes, attestation_cbor_bytes)."""
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    pub_point = leaf_key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    key_id = hashlib.sha256(pub_point).digest()

    rp_id_hash = hashlib.sha256(f"{team_id}.{bundle_id}".encode()).digest()
    cred_id = cred_id_override if cred_id_override is not None else key_id
    auth_data = (
        rp_id_hash
        + bytes([0x40])                       # flags (attested-credential-data)
        + sign_count.to_bytes(4, "big")
        + aaguid
        + len(cred_id).to_bytes(2, "big")
        + cred_id
    )

    bind_challenge = nonce_challenge if nonce_challenge is not None else challenge
    client_data_hash = hashlib.sha256(bind_challenge).digest()
    nonce = hashlib.sha256(auth_data + client_data_hash).digest()
    nonce_der = bytes([0x30, 0x24, 0xA1, 0x22, 0x04, 0x20]) + nonce

    now = datetime.utcnow()
    leaf_cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Device")]))
        .issuer_name(inter_cert.subject)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(hours=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(
            x509.UnrecognizedExtension(x509.ObjectIdentifier(_NONCE_OID), nonce_der),
            critical=False)
        .sign(inter_key, hashes.SHA384())
    )

    attestation = cbor2.dumps({
        "fmt": "apple-appattest",
        "attStmt": {
            "x5c": [
                leaf_cert.public_bytes(serialization.Encoding.DER),
                inter_cert.public_bytes(serialization.Encoding.DER),
            ],
            "receipt": b"synthetic-receipt",
        },
        "authData": auth_data,
    })
    return key_id, attestation


def _root_pem(root_cert) -> str:
    return root_cert.public_bytes(serialization.Encoding.PEM).decode()


def _mk_user(db, username="alice"):
    u = User(id=str(uuid.uuid4()), username=username, public_key="pk-" + username)
    db.add(u)
    db.commit()
    return u


# ─────────────────────────────────────────────────────────────────────
# Verifier unit tests
# ─────────────────────────────────────────────────────────────────────

def test_verify_happy_path_development():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(challenge=challenge, inter_key=ik, inter_cert=ic)
    result = verify_attestation(
        key_id=key_id, attestation=att, challenge=challenge,
        team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))
    assert result.environment == "development"
    assert result.key_id == key_id
    assert result.sign_count == 0
    assert "BEGIN PUBLIC KEY" in result.public_key_pem
    assert result.receipt == b"synthetic-receipt"


def test_verify_happy_path_production():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(
        challenge=challenge, inter_key=ik, inter_cert=ic, aaguid=_AAGUID_PROD)
    result = verify_attestation(
        key_id=key_id, attestation=att, challenge=challenge,
        team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))
    assert result.environment == "production"


def test_verify_rejects_wrong_root():
    """A chain that does NOT reach the trusted root is rejected."""
    _, _, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(challenge=challenge, inter_key=ik, inter_cert=ic)
    # Default root_ca_pem == the real Apple root — our synthetic chain
    # cannot possibly chain to it.
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE)


def test_verify_rejects_nonce_mismatch():
    _, root, ik, ic = _make_chain()
    real = secrets.token_bytes(32)
    other = secrets.token_bytes(32)
    # Cert nonce is bound to `other`, but we verify against `real`.
    key_id, att = _make_attestation(
        challenge=real, inter_key=ik, inter_cert=ic, nonce_challenge=other)
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=real,
                           team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))


def test_verify_rejects_wrong_app():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(
        challenge=challenge, inter_key=ik, inter_cert=ic, bundle_id="com.evil.clone")
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))


def test_verify_rejects_bad_key_id():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    _, att = _make_attestation(challenge=challenge, inter_key=ik, inter_cert=ic)
    with pytest.raises(AttestationError):
        verify_attestation(key_id=b"\x00" * 32, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))


def test_verify_rejects_nonzero_signcount():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(
        challenge=challenge, inter_key=ik, inter_cert=ic, sign_count=7)
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))


def test_verify_rejects_bad_credential_id():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(
        challenge=challenge, inter_key=ik, inter_cert=ic,
        cred_id_override=b"\x11" * 32)
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE, root_ca_pem=_root_pem(root))


def test_verify_rejects_malformed_cbor():
    with pytest.raises(AttestationError):
        verify_attestation(
            key_id=b"\x00" * 32,
            attestation=b"this is definitely not a valid cbor attestation",
            challenge=secrets.token_bytes(32),
            team_id=_TEAM, bundle_id=_BUNDLE)


def test_verify_rejects_development_when_disallowed():
    _, root, ik, ic = _make_chain()
    challenge = secrets.token_bytes(32)
    key_id, att = _make_attestation(challenge=challenge, inter_key=ik, inter_cert=ic)
    with pytest.raises(AttestationError):
        verify_attestation(key_id=key_id, attestation=att, challenge=challenge,
                           team_id=_TEAM, bundle_id=_BUNDLE,
                           root_ca_pem=_root_pem(root), allow_development=False)


# ─────────────────────────────────────────────────────────────────────
# Endpoint tests
# ─────────────────────────────────────────────────────────────────────

def test_challenge_endpoint_issues_unique_challenges(test_db):
    db = test_db()
    user = _mk_user(db, "alice")
    c1 = request_challenge(current_user=user, db=db)
    c2 = request_challenge(current_user=user, db=db)
    assert c1.challenge and c2.challenge and c1.challenge != c2.challenge
    assert db.query(AttestChallenge).filter(
        AttestChallenge.user_id == user.id).count() == 2
    db.close()


def test_enroll_happy_path(test_db, monkeypatch):
    _, root, ik, ic = _make_chain()
    monkeypatch.setattr(app_attest, "APPLE_APP_ATTEST_ROOT_CA", _root_pem(root))
    db = test_db()
    user = _mk_user(db, "alice")

    ch = request_challenge(current_user=user, db=db)
    challenge_raw = base64.b64decode(ch.challenge)
    key_id, att = _make_attestation(challenge=challenge_raw, inter_key=ik, inter_cert=ic)

    resp = enroll(req=EnrollRequest(
        key_id=base64.b64encode(key_id).decode(),
        attestation=base64.b64encode(att).decode(),
        challenge=ch.challenge,
    ), current_user=user, db=db)
    assert resp.enrolled is True
    assert resp.environment == "development"

    # a DeviceAttestation row now exists for the user
    rows = db.query(DeviceAttestation).filter(
        DeviceAttestation.user_id == user.id).all()
    assert len(rows) == 1
    assert rows[0].environment == "development"

    # status endpoint reflects it
    status = get_status(current_user=user, db=db)
    assert status.enrolled is True
    assert status.environment == "development"
    db.close()


def test_enroll_rejects_unknown_challenge(test_db, monkeypatch):
    _, root, ik, ic = _make_chain()
    monkeypatch.setattr(app_attest, "APPLE_APP_ATTEST_ROOT_CA", _root_pem(root))
    db = test_db()
    user = _mk_user(db, "alice")
    challenge_raw = secrets.token_bytes(32)
    key_id, att = _make_attestation(challenge=challenge_raw, inter_key=ik, inter_cert=ic)
    with pytest.raises(HTTPException) as ei:
        enroll(req=EnrollRequest(
            key_id=base64.b64encode(key_id).decode(),
            attestation=base64.b64encode(att).decode(),
            challenge=base64.b64encode(challenge_raw).decode(),  # never issued
        ), current_user=user, db=db)
    assert ei.value.status_code == 400
    db.close()


def test_enroll_rejects_reused_challenge(test_db, monkeypatch):
    _, root, ik, ic = _make_chain()
    monkeypatch.setattr(app_attest, "APPLE_APP_ATTEST_ROOT_CA", _root_pem(root))
    db = test_db()
    user = _mk_user(db, "alice")
    ch = request_challenge(current_user=user, db=db)
    key_id, att = _make_attestation(
        challenge=base64.b64decode(ch.challenge), inter_key=ik, inter_cert=ic)
    req = EnrollRequest(
        key_id=base64.b64encode(key_id).decode(),
        attestation=base64.b64encode(att).decode(),
        challenge=ch.challenge,
    )
    assert enroll(req=req, current_user=user, db=db).enrolled is True
    # second use of the same challenge is rejected
    with pytest.raises(HTTPException) as ei:
        enroll(req=req, current_user=user, db=db)
    assert ei.value.status_code == 400
    db.close()


def test_enroll_rejects_expired_challenge(test_db, monkeypatch):
    _, root, ik, ic = _make_chain()
    monkeypatch.setattr(app_attest, "APPLE_APP_ATTEST_ROOT_CA", _root_pem(root))
    db = test_db()
    user = _mk_user(db, "alice")
    ch = request_challenge(current_user=user, db=db)
    # force the challenge into the past
    row = db.query(AttestChallenge).filter(
        AttestChallenge.challenge == ch.challenge).first()
    row.expires_at = datetime.utcnow() - timedelta(minutes=10)
    db.commit()
    key_id, att = _make_attestation(
        challenge=base64.b64decode(ch.challenge), inter_key=ik, inter_cert=ic)
    with pytest.raises(HTTPException) as ei:
        enroll(req=EnrollRequest(
            key_id=base64.b64encode(key_id).decode(),
            attestation=base64.b64encode(att).decode(),
            challenge=ch.challenge,
        ), current_user=user, db=db)
    assert ei.value.status_code == 400
    db.close()


def test_enroll_rejects_tampered_attestation(test_db, monkeypatch):
    """End-to-end: a wrong-app attestation is rejected by the endpoint."""
    _, root, ik, ic = _make_chain()
    monkeypatch.setattr(app_attest, "APPLE_APP_ATTEST_ROOT_CA", _root_pem(root))
    db = test_db()
    user = _mk_user(db, "alice")
    ch = request_challenge(current_user=user, db=db)
    key_id, att = _make_attestation(
        challenge=base64.b64decode(ch.challenge), inter_key=ik, inter_cert=ic,
        bundle_id="com.evil.clone")
    with pytest.raises(HTTPException) as ei:
        enroll(req=EnrollRequest(
            key_id=base64.b64encode(key_id).decode(),
            attestation=base64.b64encode(att).decode(),
            challenge=ch.challenge,
        ), current_user=user, db=db)
    assert ei.value.status_code == 400
    db.close()
