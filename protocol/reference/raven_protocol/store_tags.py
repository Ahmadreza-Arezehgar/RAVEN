"""Privacy-preserving RavenStoreObjectV1 mailbox/store tag derivation."""

import hashlib
import hmac


MAILBOX_LABEL = b"rvn1/mailbox"
STORE_DOMAIN = b"raven/relay-tag/v1"


def mailbox_tag(k_route: bytes, epoch: int, slot: int) -> bytes:
    if not k_route:
        raise ValueError("routing key must not be empty")
    if not 0 <= epoch <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("epoch exceeds u64")
    if not 0 <= slot <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("slot exceeds u64")
    message = MAILBOX_LABEL + epoch.to_bytes(8, "big") + slot.to_bytes(8, "big")
    return hmac.new(k_route, message, hashlib.sha256).digest()[:16]


def store_tag(mailbox: bytes) -> bytes:
    if len(mailbox) != 16:
        raise ValueError("mailbox tag must be 16 bytes")
    return hashlib.sha256(STORE_DOMAIN + mailbox).digest()[:16]
