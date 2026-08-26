"""Raven (RVN1) identity + signed delegations for A2A agent nodes.

Each agent node owns an Ed25519 device key. Its RVN1 address is derived with
the same bech32m/fingerprint rules as the messenger protocol reference, and
every delegated task is signed so the receiving node can authenticate the
sending agent.

Delegations carry a random nonce and are checked against a process-wide
replay cache, so a captured (signature, payload) pair cannot be re-submitted
inside the acceptance window. A revocation list of RVN1 addresses can be
hot-reloaded from disk.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import sys
import threading
import time
from pathlib import Path

import jwt
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from jwt import PyJWK

from raven_protocol import address as rvn_address
from raven_protocol import fingerprint as rvn_fingerprint
from raven_protocol._canon import lp

SIGNING_CONTEXT = b'raven.a2a.delegation.v1'
MAX_SKEW_SECONDS = 300
NONCE_BYTES = 16


class ReplayCache:
    """Thread-safe once-only store for delegation signatures."""

    def __init__(self, ttl: int = MAX_SKEW_SECONDS * 2) -> None:
        self._ttl = ttl
        self._lock = threading.Lock()
        self._seen: dict[str, float] = {}

    def first_time(self, signature_b64: str) -> bool:
        key = hashlib.sha256(signature_b64.encode('ascii')).hexdigest()
        now = time.time()
        with self._lock:
            for k in [k for k, ts in self._seen.items() if now - ts > self._ttl]:
                del self._seen[k]
            if key in self._seen:
                return False
            self._seen[key] = now
            return True

    def __contains__(self, signature_b64: str) -> bool:
        key = hashlib.sha256(signature_b64.encode('ascii')).hexdigest()
        now = time.time()
        with self._lock:
            return key in self._seen and now - self._seen[key] <= self._ttl


_REPLAY = ReplayCache()


def load_revocations(path: str | Path) -> set[str]:
    """Accepts a JSON array of RVN1 addresses or {"revoked": [...]}."""
    raw = __import__('json').loads(Path(path).read_text(encoding='utf-8'))
    if isinstance(raw, dict):
        raw = raw.get('revoked', [])
    return {str(a) for a in raw}


def _protocol_ref_on_path() -> None:
    for base in Path(__file__).resolve().parents:
        ref = base / 'protocol' / 'reference'
        if ref.is_dir():
            if str(ref) not in sys.path:
                sys.path.insert(0, str(ref))
            return


_protocol_ref_on_path()


class RavenIdentity:
    def __init__(self, private_key: Ed25519PrivateKey) -> None:
        self._sk = private_key

    # ------------------------------------------------------------ key mgmt --
    @classmethod
    def load_or_create(cls, keys_dir: str | Path) -> 'RavenIdentity':
        d = Path(keys_dir)
        d.mkdir(parents=True, exist_ok=True)
        seed_file = d / 'device_ed25519.seed'
        if seed_file.exists():
            raw = bytes.fromhex(seed_file.read_text(encoding='utf-8').strip())
            if len(raw) != 32:
                raise ValueError(f'bad seed file: {seed_file}')
        else:
            raw = secrets.token_bytes(32)
            seed_file.write_text(raw.hex(), encoding='utf-8')
            seed_file.chmod(0o600)
        return cls(Ed25519PrivateKey.from_private_bytes(raw))

    # --------------------------------------------------------- properties --
    @property
    def public_bytes(self) -> bytes:
        raw = self._sk.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        assert isinstance(raw, bytes)
        return raw

    @property
    def public_hex(self) -> str:
        return self.public_bytes.hex()

    @property
    def address(self) -> str:
        return rvn_address.encode(self.public_bytes)

    @property
    def display_address(self) -> str:
        return rvn_address.to_display(self.address)

    @property
    def fingerprint(self) -> str:
        return rvn_fingerprint.device_fingerprint_v1(self.public_bytes)

    def identity_card(self) -> dict:
        return {
            'address': self.address,
            'display': self.display_address,
            'public_key': self.public_hex,
            'fingerprint': self.fingerprint,
        }

    # ------------------------------------------------------------- JWK ------
    def jwk_public(self) -> PyJWK:
        x = jwt.utils.base64url_encode(self.public_bytes).decode()
        return PyJWK.from_dict(
            {'kty': 'OKP', 'crv': 'Ed25519', 'x': x, 'alg': 'EdDSA'}
        )

    def jwk_private(self) -> PyJWK:
        d = jwt.utils.base64url_encode(
            self._sk.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
        ).decode()
        return PyJWK.from_dict(
            {'kty': 'OKP', 'crv': 'Ed25519', 'x': _b64url(self.public_bytes),
             'd': d, 'alg': 'EdDSA'}
        )

    # ------------------------------------------------------------ crypto ---
    def sign(self, data: bytes) -> bytes:
        return self._sk.sign(data)


def _b64url(raw: bytes) -> str:
    return jwt.utils.base64url_encode(raw).decode()


def delegation_signing_bytes(
    sender_address: str, timestamp: int, task_text: str, nonce: str = ''
) -> bytes:
    """Canonical bytes for a delegated task — length-prefixed per RVN1 _canon."""
    payload_digest = hashlib.sha256(task_text.encode('utf-8')).digest()
    nonce_raw = bytes.fromhex(nonce) if nonce else b''
    return (
        lp(SIGNING_CONTEXT)
        + lp(sender_address.encode('utf-8'))
        + lp(str(timestamp).encode('ascii'))
        + lp(payload_digest)
        + lp(nonce_raw)
    )


def sign_delegation(identity: RavenIdentity, task_text: str, timestamp: int | None = None) -> dict:
    ts = int(time.time()) if timestamp is None else timestamp
    nonce = secrets.token_hex(NONCE_BYTES)
    sig = identity.sign(delegation_signing_bytes(identity.address, ts, task_text, nonce))
    return {
        'sender': identity.address,
        'timestamp': ts,
        'nonce': nonce,
        'algorithm': 'ed25519',
        'context': SIGNING_CONTEXT.decode(),
        'signature': base64.b64encode(sig).decode('ascii'),
    }


def verify_delegation(
    meta: dict,
    task_text: str,
    trusted_peers: dict[str, str],
    required: bool = False,
    revoked: set[str] | None = None,
    replay: ReplayCache | None = None,
) -> tuple[bool, str]:
    """Check a `raven` metadata block against trust policy.

    Returns (ok, reason). Rejects revoked senders and replays the second time
    the same signature is observed (nonce-based once-only semantics).
    """
    cache = replay or _REPLAY
    if not meta:
        return (not required), 'no raven metadata' if not required else 'missing signature'
    sender = str(meta.get('sender', ''))
    if sender not in trusted_peers:
        return False, f'unknown peer: {sender or "(none)"}'
    if revoked and sender in revoked:
        return False, f'revoked peer: {sender}'
    try:
        ts = int(meta.get('timestamp', 0))
    except (TypeError, ValueError):
        return False, 'bad timestamp'
    if abs(time.time() - ts) > MAX_SKEW_SECONDS:
        return False, 'timestamp outside acceptance window'
    expected_ctx = SIGNING_CONTEXT.decode()
    if str(meta.get('context', '')) != expected_ctx:
        return False, 'bad signing context'
    nonce = str(meta.get('nonce', ''))
    if len(nonce) != NONCE_BYTES * 2:
        return False, 'missing or malformed nonce'
    try:
        bytes.fromhex(nonce)
    except ValueError:
        return False, 'malformed nonce'
    try:
        sig_b64 = str(meta.get('signature', ''))
        sig = base64.b64decode(sig_b64, validate=True)
    except Exception:  # noqa: BLE001
        return False, 'undecodable signature'
    try:
        pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(trusted_peers[sender]))
    except Exception:  # noqa: BLE001
        return False, f'malformed public key for {sender}'
    data = delegation_signing_bytes(sender, ts, task_text, nonce)
    try:
        pub.verify(sig, data)
    except InvalidSignature:
        return False, 'signature invalid'
    if not cache.first_time(sig_b64):
        return False, 'replayed delegation'
    return True, f'verified {sender}'
