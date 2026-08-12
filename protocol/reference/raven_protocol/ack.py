from dataclasses import dataclass
from ._canon import u64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

@dataclass
class Ack:
    acked_message_id: bytes; status: int; ack_nonce: bytes; created_at: int

def signing_bytes(a: Ack) -> bytes:
    return b"rvn1/ack" + a.acked_message_id + bytes([a.status]) + a.ack_nonce + u64(a.created_at)

def verify(a: Ack, sig: bytes, signer_ed_pub: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(signer_ed_pub).verify(sig, signing_bytes(a))
        return True
    except (InvalidSignature, ValueError):
        return False
