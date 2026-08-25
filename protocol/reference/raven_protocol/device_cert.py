from dataclasses import dataclass, field
from ._canon import lp, u64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

@dataclass
class DeviceCert:
    device_ed_pub: bytes; device_x_pub: bytes; device_id: str
    not_before: int; not_after: int; capabilities: int
    signature: bytes = field(default=b"")

def signing_bytes(c: DeviceCert) -> bytes:
    return (b"rvn1/devcert" + lp(c.device_ed_pub) + lp(c.device_x_pub)
            + lp(c.device_id.encode()) + u64(c.not_before) + u64(c.not_after) + u64(c.capabilities))

def verify(c: DeviceCert, user_identity_ed_pub: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(user_identity_ed_pub).verify(c.signature, signing_bytes(c))
        return True
    except (InvalidSignature, ValueError):
        return False
