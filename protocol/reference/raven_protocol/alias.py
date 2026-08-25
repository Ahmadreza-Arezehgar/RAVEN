from dataclasses import dataclass, field
from ._canon import lp, u64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

@dataclass
class AliasRecord:
    alias: str; identity_address: str; sequence: int; expires_at: int
    signature: bytes = field(default=b"")

def signing_bytes(r: AliasRecord) -> bytes:
    return (b"rvn1/alias" + lp(r.alias.encode()) + lp(r.identity_address.encode())
            + u64(r.sequence) + u64(r.expires_at))

def verify(r: AliasRecord, identity_ed_pub: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(identity_ed_pub).verify(r.signature, signing_bytes(r))
        return True
    except (InvalidSignature, ValueError):
        return False
