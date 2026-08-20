"""Independent PQCKA authenticator primitives for the Full Braid reference."""

from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass

INFO_AUTH_UPDATE = b"Signal_PQCKA_V1_MLKEM768:Authenticator Update"
INFO_EKHEADER = b"Signal_PQCKA_V1_MLKEM768:ekheader"
INFO_CIPHERTEXT = b"Signal_PQCKA_V1_MLKEM768:ciphertext"
INFO_SCKA_KEY = b"Signal_PQCKA_V1_MLKEM768:SCKA Key"
ZERO_SALT = bytes(32)


def _hkdf_sha256(salt: bytes, ikm: bytes, info: bytes, length: int) -> bytes:
    if length < 0 or length > 255 * hashlib.sha256().digest_size:
        raise ValueError("invalid HKDF length")
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    output = bytearray()
    previous = b""
    counter = 1
    while len(output) < length:
        previous = hmac.new(
            prk, previous + info + bytes([counter]), hashlib.sha256
        ).digest()
        output.extend(previous)
        counter += 1
    return bytes(output[:length])


def kdf_ok(shared_secret: bytes, epoch: int) -> bytes:
    """Derive the epoch-bound SCKA output key from an ML-KEM shared secret."""
    if len(shared_secret) != 32:
        raise ValueError("shared secret must be 32 bytes")
    return _hkdf_sha256(
        ZERO_SALT,
        shared_secret,
        INFO_SCKA_KEY + int(epoch).to_bytes(8, "big"),
        32,
    )


@dataclass
class AuthState:
    root_key: bytes
    mac_key: bytes

    def __post_init__(self) -> None:
        if len(self.root_key) != 32 or len(self.mac_key) != 32:
            raise ValueError("auth keys must be 32 bytes")

    @classmethod
    def init(cls, epoch: int, key: bytes) -> "AuthState":
        state = cls(root_key=bytes(32), mac_key=bytes(32))
        state.update(epoch, key)
        return state

    def update(self, epoch: int, update_key: bytes) -> None:
        info = INFO_AUTH_UPDATE + int(epoch).to_bytes(8, "big")
        okm = _hkdf_sha256(ZERO_SALT, self.root_key + update_key, info, 64)
        self.root_key = okm[:32]
        self.mac_key = okm[32:]

    def _mac(self, label: bytes, epoch: int, body: bytes) -> bytes:
        return hmac.new(
            self.mac_key,
            label + int(epoch).to_bytes(8, "big") + body,
            hashlib.sha256,
        ).digest()

    def mac_hdr(self, epoch: int, header: bytes) -> bytes:
        return self._mac(INFO_EKHEADER, epoch, header)

    def mac_ct(self, epoch: int, ciphertext: bytes) -> bytes:
        return self._mac(INFO_CIPHERTEXT, epoch, ciphertext)

    def verify_hdr(self, epoch: int, header: bytes, expected: bytes) -> bool:
        return hmac.compare_digest(self.mac_hdr(epoch, header), expected)

    def verify_ct(self, epoch: int, ciphertext: bytes, expected: bytes) -> bool:
        return hmac.compare_digest(self.mac_ct(epoch, ciphertext), expected)
