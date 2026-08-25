"""Full Braid Slice 2 digests (design §2.3) — computing reference.

Must match `node/crates/raven-core/.../hybrid_ratchet_v2_full_braid/digest.rs`
byte-for-byte. Deterministic only.
"""

from __future__ import annotations

import hashlib

DOMAIN_STATE = b"ATSAM/v2/full-braid/state"
DOMAIN_INPUT = b"ATSAM/v2/full-braid/input"
DOMAIN_EXECUTION = b"ATSAM/v2/full-braid/execution"
DOMAIN_OUTPUT = b"ATSAM/v2/full-braid/output"
DOMAIN_SEND_SOURCE = b"ATSAM/v2/braid-send-source"
DOMAIN_BRAID_OBJECT = b"ATSAM/v2/braid-object"
DOMAIN_BRAID_CHUNK = b"ATSAM/v2/braid-chunk"
DOMAIN_TRANSITION_ID = b"ATSAM/v2/full-braid/transition-id"


def _u16be(n: int) -> bytes:
    return int(n).to_bytes(2, "big")


def _u32be(n: int) -> bytes:
    return int(n).to_bytes(4, "big")


def _u64be(n: int) -> bytes:
    return int(n).to_bytes(8, "big")


def state_digest(schema_rev: int, rvfb1_bytes: bytes) -> bytes:
    return hashlib.sha256(DOMAIN_STATE + _u16be(schema_rev) + rvfb1_bytes).digest()


def input_digest(rvbi1_bytes: bytes) -> bytes:
    return hashlib.sha256(DOMAIN_INPUT + rvbi1_bytes).digest()


def execution_digest(rvbi1_bytes: bytes, rvbe1_bytes: bytes) -> bytes:
    return hashlib.sha256(
        DOMAIN_EXECUTION
        + _u32be(len(rvbi1_bytes))
        + rvbi1_bytes
        + _u32be(len(rvbe1_bytes))
        + rvbe1_bytes
    ).digest()


def output_digest(rvbo1_bytes: bytes) -> bytes:
    return hashlib.sha256(DOMAIN_OUTPUT + rvbo1_bytes).digest()


def object_digest(endpoint_object_bytes: bytes) -> bytes:
    return hashlib.sha256(endpoint_object_bytes).digest()


def send_source_digest(source_bytes: bytes) -> bytes:
    return hashlib.sha256(DOMAIN_SEND_SOURCE + source_bytes).digest()


def braid_object_digest(
    session_id: bytes,
    direction: int,
    epoch: int,
    source_kind: int,
    source_bytes: bytes,
) -> bytes:
    if len(session_id) != 32:
        raise ValueError("session_id must be 32 bytes")
    return hashlib.sha256(
        DOMAIN_BRAID_OBJECT
        + session_id
        + bytes([direction & 0xFF])
        + _u64be(epoch)
        + bytes([source_kind & 0xFF])
        + source_bytes
    ).digest()


def binding_digest(
    direction: int,
    epoch: int,
    chunk_type: int,
    index: int,
    payload: bytes,
    session_id: bytes,
) -> bytes:
    if len(session_id) != 32:
        raise ValueError("session_id must be 32 bytes")
    return hashlib.sha256(
        DOMAIN_BRAID_CHUNK
        + bytes([direction & 0xFF])
        + _u64be(epoch)
        + bytes([chunk_type & 0xFF])
        + _u32be(index)
        + payload
        + session_id
    ).digest()


def transition_id_digest(
    session_id: bytes,
    role: int,
    direction: int,
    generation: int,
    execution: bytes,
    before_state: bytes,
) -> bytes:
    if len(session_id) != 32 or len(execution) != 32 or len(before_state) != 32:
        raise ValueError("digest fields must be 32 bytes")
    return hashlib.sha256(
        DOMAIN_TRANSITION_ID
        + session_id
        + bytes([role & 0xFF])
        + bytes([direction & 0xFF])
        + _u64be(generation)
        + execution
        + before_state
    ).digest()


def domain_catalog() -> dict[str, str]:
    """Hex catalog for shared-vector freeze (domain label bytes)."""
    return {
        "DOMAIN_STATE": DOMAIN_STATE.hex(),
        "DOMAIN_INPUT": DOMAIN_INPUT.hex(),
        "DOMAIN_EXECUTION": DOMAIN_EXECUTION.hex(),
        "DOMAIN_OUTPUT": DOMAIN_OUTPUT.hex(),
        "DOMAIN_SEND_SOURCE": DOMAIN_SEND_SOURCE.hex(),
        "DOMAIN_BRAID_OBJECT": DOMAIN_BRAID_OBJECT.hex(),
        "DOMAIN_BRAID_CHUNK": DOMAIN_BRAID_CHUNK.hex(),
        "DOMAIN_TRANSITION_ID": DOMAIN_TRANSITION_ID.hex(),
        "RVBE1_SCHEMA": "0002",
        "EMPTY_RVBO1_LEN": "14",
    }
