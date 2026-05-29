"""Tests for the QR-code desktop-linking flow (`server/routers/qr_login.py`).

Exercises happy path + the security-relevant edge cases: tampered signature,
unauthenticated scan, replay of consumed session, single-use enforcement,
deny, and timestamp-skew rejection.
"""

import time
from datetime import datetime, timedelta

import pytest

from .conftest import flutter_sign


def _init_session(client) -> dict:
    r = client.post("/api/auth/qr-login/init")
    assert r.status_code == 200, r.text
    return r.json()


def _scan(client, token: str, body: dict) -> "object":
    return client.post(
        "/api/auth/qr-login/scan",
        json=body,
        headers={"Authorization": f"Bearer {token}"},
    )


def _approve(client, token: str, body: dict) -> "object":
    return client.post(
        "/api/auth/qr-login/approve",
        json=body,
        headers={"Authorization": f"Bearer {token}"},
    )


def _poll(client, session_id: str, nonce: str) -> "object":
    return client.get(f"/api/auth/qr-login/poll/{session_id}", params={"nonce": nonce})


def _build_scan_body(session: dict, private_key, device_fp: str = "ABC12345"):
    ts = int(time.time())
    payload = f"v1|{session['sessionId']}|{session['nonce']}|{device_fp}|{ts}"
    return {
        "sessionId": session["sessionId"],
        "nonce": session["nonce"],
        "timestamp": ts,
        "deviceFingerprint": device_fp,
        "signature": flutter_sign(private_key, payload),
    }


def _build_approve_body(session_id: str, private_key, name: str = "Ahmad's Mac"):
    ts = int(time.time())
    payload = f"{session_id}|approved|{ts}"
    return {
        "sessionId": session_id,
        "timestamp": ts,
        "signature": flutter_sign(private_key, payload),
        "desktopDeviceName": name,
        "desktopDeviceModel": "MacBook Pro",
        "desktopDeviceOs": "macOS 14",
    }


def test_happy_path(client, make_user):
    uid, priv, jwt = make_user(username="alice")
    session = _init_session(client)
    assert session["sessionId"] and session["nonce"]

    # Pre-scan, status is pending
    r = _poll(client, session["sessionId"], session["nonce"])
    assert r.status_code == 200
    assert r.json()["status"] == "pending"

    # Mobile scans
    r = _scan(client, jwt, _build_scan_body(session, priv))
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "scanned"

    # Desktop sees scanned
    r = _poll(client, session["sessionId"], session["nonce"])
    assert r.status_code == 200
    assert r.json()["status"] == "scanned"

    # Mobile approves
    r = _approve(client, jwt, _build_approve_body(session["sessionId"], priv))
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "approved"

    # Desktop polls and gets tokens
    r = _poll(client, session["sessionId"], session["nonce"])
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "approved"
    assert body["token"] and body["refreshToken"]
    assert body["userId"] == uid
    assert body["username"] == "alice"


def test_single_use_consume(client, make_user):
    """Once the desktop polls and gets the token, subsequent polls return
    `expired` even though the session row says approved."""
    uid, priv, jwt = make_user()
    session = _init_session(client)
    _scan(client, jwt, _build_scan_body(session, priv))
    _approve(client, jwt, _build_approve_body(session["sessionId"], priv))

    r1 = _poll(client, session["sessionId"], session["nonce"])
    assert r1.json()["status"] == "approved"
    assert r1.json()["token"]

    r2 = _poll(client, session["sessionId"], session["nonce"])
    assert r2.json()["status"] == "expired"
    assert r2.json().get("token") is None


def test_bad_nonce_on_poll(client):
    session = _init_session(client)
    r = _poll(client, session["sessionId"], "wrong-nonce")
    assert r.status_code == 403


def test_unauthenticated_scan(client):
    session = _init_session(client)
    r = client.post(
        "/api/auth/qr-login/scan",
        json={
            "sessionId": session["sessionId"],
            "nonce": session["nonce"],
            "timestamp": int(time.time()),
            "deviceFingerprint": "AAAA",
            "signature": "bogus",
        },
    )
    assert r.status_code == 401


def test_tampered_signature(client, make_user):
    _, priv, jwt = make_user()
    session = _init_session(client)
    body = _build_scan_body(session, priv)
    body["signature"] = body["signature"][:-4] + "AAAA"  # corrupt last bytes
    r = _scan(client, jwt, body)
    assert r.status_code == 401


def test_timestamp_skew_rejected(client, make_user):
    _, priv, jwt = make_user()
    session = _init_session(client)
    body = _build_scan_body(session, priv)
    body["timestamp"] = int(time.time()) - 600  # 10 min in the past
    # Re-sign with the skewed timestamp so the signature is internally valid;
    # only the timestamp check should fail.
    payload = f"v1|{body['sessionId']}|{body['nonce']}|{body['deviceFingerprint']}|{body['timestamp']}"
    body["signature"] = flutter_sign(priv, payload)
    r = _scan(client, jwt, body)
    assert r.status_code == 400


def test_deny_flow(client, make_user):
    _, priv, jwt = make_user()
    session = _init_session(client)
    _scan(client, jwt, _build_scan_body(session, priv))
    r = client.post(
        "/api/auth/qr-login/deny",
        json={"sessionId": session["sessionId"]},
        headers={"Authorization": f"Bearer {jwt}"},
    )
    assert r.status_code == 200
    assert r.json()["status"] == "denied"

    r = _poll(client, session["sessionId"], session["nonce"])
    assert r.json()["status"] == "denied"


def test_cannot_rescan_same_session(client, make_user):
    _, priv, jwt = make_user()
    session = _init_session(client)
    r1 = _scan(client, jwt, _build_scan_body(session, priv))
    assert r1.status_code == 200

    r2 = _scan(client, jwt, _build_scan_body(session, priv))
    assert r2.status_code == 409  # already scanned, not pending


def test_approve_requires_scan_first(client, make_user):
    _, priv, jwt = make_user()
    session = _init_session(client)
    r = _approve(client, jwt, _build_approve_body(session["sessionId"], priv))
    # Session is `pending`, not `scanned`, so approve is rejected.
    assert r.status_code == 409


def test_expired_session(client, make_user):
    """Manually expire the row in the DB and confirm poll/scan reject it."""
    from routers.qr_login import QrLoginSession

    _, priv, jwt = make_user()
    session = _init_session(client)

    # Backdate the row directly via the test DB factory stashed on client.
    db = client._test_db_factory()
    try:
        row = db.query(QrLoginSession).filter(QrLoginSession.id == session["sessionId"]).first()
        row.expires_at = datetime.utcnow() - timedelta(seconds=1)
        db.commit()
    finally:
        db.close()

    r = _scan(client, jwt, _build_scan_body(session, priv))
    assert r.status_code == 410


def test_cross_user_cannot_approve(client, make_user, rsa_keypair):
    """User B cannot approve a session that User A scanned."""
    _, priv_a, jwt_a = make_user(username="alice")
    # Different user — note: we want a user with a valid public key and JWT.
    # The shared `rsa_keypair` fixture is the same one used inside make_user,
    # so re-using make_user gives us the right shape.
    _, _, jwt_b = make_user(username="bob")

    session = _init_session(client)
    _scan(client, jwt_a, _build_scan_body(session, priv_a))

    # Bob approves with HIS JWT but Alice's signature — server checks
    # mobile_user_id == current_user.id BEFORE verifying signature, so this
    # should be 403, not 401.
    body = _build_approve_body(session["sessionId"], priv_a)
    r = _approve(client, jwt_b, body)
    assert r.status_code == 403
