# raven_protocol/envelope.py
import hashlib, struct
from dataclasses import dataclass
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

MAGIC = b"RVN1"
VERSION = 1
PREFIX_FMT = ">4sBBH16s16sQQQBB12sHIH"   # 86 bytes
PREFIX_LEN = struct.calcsize(PREFIX_FMT)
assert PREFIX_LEN == 86

@dataclass
class Envelope:
    env_type: int; flags: int
    message_id: bytes; routing_tag: bytes
    dest_device_hint: int; created_at: int; expires_at: int
    hop_limit: int; replication_budget: int; anti_replay_nonce: bytes
    ratchet_header_ciphertext: bytes; message_ciphertext: bytes
    sender_authentication: bytes

def pack(e: Envelope) -> bytes:
    prefix = struct.pack(
        PREFIX_FMT, MAGIC, VERSION, e.env_type, e.flags,
        e.message_id, e.routing_tag, e.dest_device_hint,
        e.created_at, e.expires_at, e.hop_limit, e.replication_budget,
        e.anti_replay_nonce, len(e.ratchet_header_ciphertext),
        len(e.message_ciphertext), len(e.sender_authentication),
    )
    return prefix + e.ratchet_header_ciphertext + e.message_ciphertext + e.sender_authentication

def unpack(raw: bytes):
    if len(raw) < PREFIX_LEN or raw[:4] != MAGIC or raw[4] != VERSION:
        return None
    (_, _, env_type, flags, message_id, routing_tag, dest_hint, created_at,
     expires_at, hop_limit, repl, nonce, hdr_len, body_len, auth_len) = struct.unpack(
        PREFIX_FMT, raw[:PREFIX_LEN])
    o = PREFIX_LEN
    if len(raw) != o + hdr_len + body_len + auth_len:
        return None
    hdr = raw[o:o+hdr_len]; o += hdr_len
    body = raw[o:o+body_len]; o += body_len
    auth = raw[o:o+auth_len]
    return Envelope(env_type, flags, message_id, routing_tag, dest_hint, created_at,
                    expires_at, hop_limit, repl, nonce, hdr, body, auth)

def signing_bytes(e: Envelope) -> bytes:
    # Zero the three relay-mutable fields; bind ciphertext blobs by hash.
    prefix = struct.pack(
        PREFIX_FMT, MAGIC, VERSION, e.env_type, e.flags,
        e.message_id, e.routing_tag, 0,          # dest_device_hint zeroed
        e.created_at, e.expires_at, 0, 0,        # hop_limit, replication_budget zeroed
        e.anti_replay_nonce, len(e.ratchet_header_ciphertext),
        len(e.message_ciphertext), 64,           # canonical auth_len for signing = 64
    )
    return prefix + hashlib.sha256(e.ratchet_header_ciphertext).digest() \
                  + hashlib.sha256(e.message_ciphertext).digest()

def verify(e: Envelope, signer_ed_pub: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(signer_ed_pub).verify(
            e.sender_authentication, signing_bytes(e))
        return True
    except (InvalidSignature, ValueError):
        return False
