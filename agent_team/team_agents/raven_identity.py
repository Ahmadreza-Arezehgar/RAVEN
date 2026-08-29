"""Raven (RVN1) identity + signed delegations for A2A agent nodes.

Each agent node owns an Ed25519 device key. Its RVN1 address is derived with
the same bech32m/fingerprint rules as the messenger protocol reference, and
every delegated task is signed so the receiving node can authenticate the
sending agent.

Delegations bind sender, recipient, task id, message kind and an explicit
expiry.  Received signatures are recorded in a durable SQLite replay cache so
restarting a node does not reopen the replay window.  A revocation list of
RVN1 addresses can be hot-reloaded from disk.
"""

from __future__ import annotations

import base64
import hashlib
import os
import secrets
import sqlite3
import stat
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

SIGNING_CONTEXT = b'raven.a2a.delegation.v2'
MAX_FUTURE_SKEW_SECONDS = 60
DEFAULT_DELEGATION_TTL_SECONDS = 10 * 60
MAX_DELEGATION_TTL_SECONDS = 24 * 60 * 60
NONCE_BYTES = 16


class ReplayCache:
    """Thread-safe once-only store, optionally durable across restarts."""

    def __init__(
        self,
        ttl: int = MAX_DELEGATION_TTL_SECONDS + MAX_FUTURE_SKEW_SECONDS,
        path: str | Path | None = None,
    ) -> None:
        self._ttl = ttl
        self._path = Path(path) if path else None
        self._lock = threading.Lock()
        self._seen: dict[str, float] = {}
        if self._path is not None:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            with sqlite3.connect(self._path) as db:
                db.execute(
                    'CREATE TABLE IF NOT EXISTS replay_signatures ('
                    'signature_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)'
                )
            try:
                self._path.chmod(0o600)
            except OSError:
                pass

    def first_time(self, signature_b64: str, expires_at: int | None = None) -> bool:
        key = hashlib.sha256(signature_b64.encode('ascii')).hexdigest()
        now = time.time()
        expiry = int(expires_at if expires_at is not None else now + self._ttl)
        if self._path is not None:
            # SQLite gives us an atomic cross-thread/process check-and-insert and
            # works on Windows, unlike an fcntl-based lock file.
            try:
                with self._lock, sqlite3.connect(self._path, timeout=5) as db:
                    db.execute('BEGIN IMMEDIATE')
                    existing = db.execute(
                        'SELECT expires_at FROM replay_signatures '
                        'WHERE signature_hash = ?',
                        (key,),
                    ).fetchone()
                    if existing and int(existing[0]) >= int(now):
                        # Roll back even though this transaction made no logical
                        # change: a rejected replay must remain mutation-free.
                        db.rollback()
                        return False
                    if existing:
                        db.execute(
                            'DELETE FROM replay_signatures WHERE signature_hash = ?',
                            (key,),
                        )
                    db.execute(
                        'INSERT INTO replay_signatures(signature_hash, expires_at) '
                        'VALUES (?, ?)',
                        (key, expiry),
                    )
                    # Housekeeping happens only as part of accepting a fresh
                    # signature, never because rejected traffic reached us.
                    db.execute(
                        'DELETE FROM replay_signatures '
                        'WHERE expires_at < ? AND signature_hash != ?',
                        (int(now), key),
                    )
                return True
            except sqlite3.Error:
                # Replay persistence is part of authentication.  A broken or
                # unwritable cache therefore fails closed.
                return False
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
        if self._path is not None:
            try:
                with sqlite3.connect(self._path) as db:
                    row = db.execute(
                        'SELECT expires_at FROM replay_signatures '
                        'WHERE signature_hash = ?',
                        (key,),
                    ).fetchone()
                return bool(row and int(row[0]) >= int(now))
            except sqlite3.Error:
                return True
        with self._lock:
            return key in self._seen and now - self._seen[key] <= self._ttl


_REPLAY = ReplayCache()


def load_revocations(path: str | Path) -> set[str]:
    """Accepts a JSON array of RVN1 addresses or {"revoked": [...]}."""
    raw = __import__('json').loads(Path(path).read_text(encoding='utf-8'))
    if isinstance(raw, dict):
        raw = raw.get('revoked', [])
    if not isinstance(raw, list):
        raise ValueError('revocation file must be a JSON list or {"revoked": [...]}')
    revoked = {str(a) for a in raw}
    for address in revoked:
        try:
            public_hash, version = rvn_address.decode(address)
        except Exception as exc:  # noqa: BLE001
            raise ValueError(f'invalid revoked RVN address: {address}') from exc
        if version != 1 or len(public_hash) != 20:
            raise ValueError(f'invalid revoked RVN address: {address}')
    return revoked


def _protocol_ref_on_path() -> None:
    for base in Path(__file__).resolve().parents:
        ref = base / 'protocol' / 'reference'
        if ref.is_dir():
            if str(ref) not in sys.path:
                sys.path.insert(0, str(ref))
            return


_protocol_ref_on_path()


def validate_address_public_key(address: str, public_key_hex: str) -> bytes:
    """Validate and return a peer's raw Ed25519 key.

    Trust files and discovery records must never be allowed to pair an RVN
    address with an unrelated public key.  Deriving the address from the key
    also validates key length, hexadecimal encoding and canonical address
    spelling in one place.
    """
    try:
        public_key = bytes.fromhex(str(public_key_hex))
    except ValueError as exc:
        raise ValueError('public key must be hexadecimal') from exc
    if len(public_key) != 32:
        raise ValueError('public key must be exactly 32 bytes')
    derived = rvn_address.encode(public_key)
    if not secrets.compare_digest(str(address), derived):
        raise ValueError(f'RVN address/public-key mismatch: expected {derived}')
    return public_key


def fingerprint_for_public_key(public_key_hex: str) -> str:
    try:
        public_key = bytes.fromhex(str(public_key_hex))
    except ValueError as exc:
        raise ValueError('public key must be hexadecimal') from exc
    if len(public_key) != 32:
        raise ValueError('public key must be exactly 32 bytes')
    return rvn_fingerprint.device_fingerprint_v1(public_key)


class RavenIdentity:
    def __init__(self, private_key: Ed25519PrivateKey) -> None:
        self._sk = private_key

    # ------------------------------------------------------------ key mgmt --
    @classmethod
    def load_or_create(cls, keys_dir: str | Path) -> 'RavenIdentity':
        d = Path(keys_dir)
        d.mkdir(parents=True, exist_ok=True)
        if d.is_symlink() or not d.is_dir():
            raise ValueError(f'keys directory must be a real directory: {d}')
        seed_file = d / 'device_ed25519.seed'
        if seed_file.exists():
            if seed_file.is_symlink():
                raise ValueError(f'seed path must be a regular non-symlink file: {seed_file}')
            flags = os.O_RDONLY
            if hasattr(os, 'O_NOFOLLOW'):
                flags |= os.O_NOFOLLOW
            fd = os.open(seed_file, flags)
            with os.fdopen(fd, 'r', encoding='utf-8') as handle:
                st = os.fstat(handle.fileno())
                if not stat.S_ISREG(st.st_mode):
                    raise ValueError(
                        f'seed path must be a regular non-symlink file: {seed_file}'
                    )
                if os.name != 'nt':
                    if st.st_mode & 0o077:
                        raise PermissionError(
                            f'seed file permissions must be 0600: {seed_file}'
                        )
                    if hasattr(os, 'getuid') and st.st_uid != os.getuid():
                        raise PermissionError(
                            f'seed file must be owned by the current user: {seed_file}'
                        )
                encoded = handle.read().strip()
            raw = bytes.fromhex(encoded)
            if len(raw) != 32:
                raise ValueError(f'bad seed file: {seed_file}')
        else:
            raw = secrets.token_bytes(32)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, 'O_NOFOLLOW'):
                flags |= os.O_NOFOLLOW
            fd = os.open(seed_file, flags, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                handle.write(raw.hex())
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
    sender_address: str,
    recipient_address: str,
    task_id: str,
    kind: str,
    issued_at: int,
    expires_at: int,
    task_text: str,
    nonce: str,
) -> bytes:
    """Canonical signed bytes, length-prefixed per RVN1 ``_canon``."""
    payload_digest = hashlib.sha256(task_text.encode('utf-8')).digest()
    nonce_raw = bytes.fromhex(nonce)
    return (
        lp(SIGNING_CONTEXT)
        + lp(sender_address.encode('utf-8'))
        + lp(recipient_address.encode('utf-8'))
        + lp(task_id.encode('utf-8'))
        + lp(kind.encode('ascii'))
        + lp(str(issued_at).encode('ascii'))
        + lp(str(expires_at).encode('ascii'))
        + lp(payload_digest)
        + lp(nonce_raw)
    )


def sign_delegation(
    identity: RavenIdentity,
    task_text: str,
    *,
    recipient: str,
    task_id: str,
    kind: str = 'task',
    issued_at: int | None = None,
    expires_at: int | None = None,
    ttl_seconds: int = DEFAULT_DELEGATION_TTL_SECONDS,
) -> dict:
    """Sign an exact task/reply for one recipient and bounded lifetime."""
    validate_address_public_key(identity.address, identity.public_hex)
    if not recipient or not task_id:
        raise ValueError('recipient and task_id are required')
    if kind not in {'task', 'answer'}:
        raise ValueError('kind must be task or answer')
    now = int(time.time()) if issued_at is None else int(issued_at)
    expiry = now + int(ttl_seconds) if expires_at is None else int(expires_at)
    lifetime = expiry - now
    if lifetime <= 0 or lifetime > MAX_DELEGATION_TTL_SECONDS:
        raise ValueError('delegation lifetime is outside the allowed range')
    nonce = secrets.token_hex(NONCE_BYTES)
    sig = identity.sign(
        delegation_signing_bytes(
            identity.address,
            recipient,
            task_id,
            kind,
            now,
            expiry,
            task_text,
            nonce,
        )
    )
    return {
        'sender': identity.address,
        'recipient': recipient,
        'task_id': task_id,
        'kind': kind,
        'issued_at': now,
        'expires_at': expiry,
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
    expected_recipient: str = '',
    expected_task_id: str = '',
    expected_kind: str = 'task',
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
    expected_ctx = SIGNING_CONTEXT.decode()
    if str(meta.get('context', '')) != expected_ctx:
        return False, 'bad signing context'
    if not expected_recipient or not expected_task_id:
        return False, 'verifier missing recipient or task id'
    recipient = str(meta.get('recipient', ''))
    task_id = str(meta.get('task_id', ''))
    kind = str(meta.get('kind', ''))
    if recipient != expected_recipient:
        return False, 'delegation recipient mismatch'
    if task_id != expected_task_id:
        return False, 'delegation task id mismatch'
    if kind != expected_kind:
        return False, 'delegation kind mismatch'
    try:
        issued_at = int(meta.get('issued_at', 0))
        expires_at = int(meta.get('expires_at', 0))
    except (TypeError, ValueError):
        return False, 'bad delegation time bounds'
    now = int(time.time())
    if issued_at > now + MAX_FUTURE_SKEW_SECONDS:
        return False, 'delegation issued too far in the future'
    if expires_at <= issued_at:
        return False, 'invalid delegation expiry'
    if expires_at - issued_at > MAX_DELEGATION_TTL_SECONDS:
        return False, 'delegation lifetime exceeds maximum'
    if now > expires_at:
        return False, 'delegation expired'
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
        public_key = validate_address_public_key(sender, trusted_peers[sender])
        pub = Ed25519PublicKey.from_public_bytes(public_key)
    except Exception as exc:  # noqa: BLE001
        return False, f'invalid trusted identity for {sender}: {exc}'
    data = delegation_signing_bytes(
        sender,
        recipient,
        task_id,
        kind,
        issued_at,
        expires_at,
        task_text,
        nonce,
    )
    try:
        pub.verify(sig, data)
    except InvalidSignature:
        return False, 'signature invalid'
    if not cache.first_time(sig_b64, expires_at=expires_at):
        return False, 'replayed delegation'
    return True, f'verified {sender}'
