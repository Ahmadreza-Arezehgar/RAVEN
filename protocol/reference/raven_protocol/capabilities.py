from dataclasses import dataclass, field
from ._canon import lp, u64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature


@dataclass
class Capabilities:
    identity_address: str
    capability_bits: int
    expires_at: int
    signature: bytes = field(default=b"")


def signing_bytes(c: Capabilities) -> bytes:
    return (b"rvn1/caps" + lp(c.identity_address.encode())
            + u64(c.capability_bits) + u64(c.expires_at))


def verify(c: Capabilities, identity_ed_pub: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(identity_ed_pub).verify(c.signature, signing_bytes(c))
        return True
    except (InvalidSignature, ValueError):
        return False
