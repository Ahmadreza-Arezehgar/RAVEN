"""Full Braid Slice 3 Task 0B.1 — protected seed / RVFA1 computing reference.

Lab-only. Matches durability design §3.1–§3.3, §7, §10.1 and Task 0B design.
No OS credential backends (0B.2+). Production disabled.
"""

from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from enum import Enum, IntEnum
from typing import Optional, Sequence


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-SHA256 extract+expand (all-zero salt when empty)."""
    if not salt:
        salt = b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    t = b""
    okm = b""
    counter = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        okm += t
        counter += 1
    # Best-effort wipe of temporaries (CPython bytes are immutable; overwrite refs).
    del prk, t
    return okm[:length]


RVFA1_LEN = 204
RVFA1_PREFIX_LEN = 172
SEED_LEN = 32
INITIAL_ANCHOR_SEQ = 1
SCOPE_DOMAIN = b"ATSAM/v2/full-braid/durable/platform-scope"
RECORD_DOMAIN = b"ATSAM/v2/full-braid/durable/record"
APPLE_APP_ID = b"app.raven.ios"
APPLE_LOGICAL_ROOT = b"group.app.raven.fullbraid"
TERMINAL_APP_ID = b"app.raven.node"
FORBIDDEN_APPLE_ROOTS = (
    b"group.app.raven.shared",
    b"group.app.raven.ios",
)

HKDF_ZERO_SALT = bytes(32)

INFO_STATE = b"ATSAM/v2/full-braid/durable/state-aead"
INFO_INDEX = b"ATSAM/v2/full-braid/durable/index"
INFO_SQL = b"ATSAM/v2/full-braid/durable/sqlcipher"
INFO_LOCAL = b"ATSAM/v2/full-braid/durable/domain-local"
INFO_ANCHOR = b"ATSAM/v2/full-braid/durable/anchor"
INFO_SQL_SALT = b"ATSAM/v2/full-braid/durable/sqlcipher-salt"
INFO_STATE_RECORD = b"ATSAM/v2/full-braid/durable/state-record"
INFO_STAGE = b"ATSAM/v2/full-braid/durable/domain-stage"

RVFA1_MAGIC = b"RVFA1\0\0\0"
RVFA1_SCHEMA = 1

APPLE_SEED_SERVICE = "app.raven.atsam.full-braid.store.v1"
APPLE_ANCHOR_SERVICE = "app.raven.atsam.full-braid.anchor.v1"
LINUX_APPLICATION = "app.raven.node"
LINUX_PROTOCOL = "atsam-full-braid-v1"
WINDOWS_TARGET_PREFIX = "Raven/ATSAM/FullBraid/v1"
WINDOWS_CRED_MAX_BLOB = 2560
MAX_FULL_BRAID_SESSIONS = 4096
RELEASE_HOLD = "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"

ERROR_CODES = (
    "UNAVAILABLE",
    "LOCKED_OR_PROMPT_REQUIRED",
    "MISSING",
    "DUPLICATE",
    "CONFLICT",
    "CORRUPT_LENGTH",
    "CORRUPT_ATTRIBUTES",
    "WRONG_ACCESSIBILITY_OR_PERSISTENCE",
    "CAPACITY",
    "READBACK_MISMATCH",
    "IO_OR_PLATFORM",
)


class Rvfa1Status(IntEnum):
    HEAD = 1
    DELETING = 2
    TOMBSTONE = 3


class AppendDecision(str, Enum):
    APPENDED = "Appended"
    EXACT_REPLAY = "ExactReplay"
    CORRUPT = "Corrupt"


class CodecError(ValueError):
    pass


def _u16be(n: int) -> bytes:
    return int(n).to_bytes(2, "big")


def _u32be(n: int) -> bytes:
    return int(n).to_bytes(4, "big")


def _u64be(n: int) -> bytes:
    return int(n).to_bytes(8, "big")


def _require_len(value: bytes, length: int, name: str) -> bytes:
    if len(value) != length:
        raise CodecError(f"{name} must be {length} bytes")
    return value


def scope_id(platform_app_id: bytes, logical_root_id: bytes) -> bytes:
    if not platform_app_id or not logical_root_id:
        raise CodecError("scope components must be non-empty")
    if logical_root_id in FORBIDDEN_APPLE_ROOTS:
        raise CodecError("forbidden Raven App Group fallback")
    return hashlib.sha256(
        SCOPE_DOMAIN
        + _u32be(len(platform_app_id))
        + platform_app_id
        + _u32be(len(logical_root_id))
        + logical_root_id
    ).digest()


def apple_scope_id() -> bytes:
    return scope_id(APPLE_APP_ID, APPLE_LOGICAL_ROOT)


def terminal_scope_id(canonical_root_bytes: bytes) -> bytes:
    return scope_id(TERMINAL_APP_ID, canonical_root_bytes)


@dataclass(frozen=True)
class DerivedKeys:
    k_state: bytes
    k_index: bytes
    k_sql: bytes
    k_local: bytes
    k_anchor: bytes
    k_sql_salt: bytes


def derive_store_keys(seed32: bytes) -> DerivedKeys:
    seed = _require_len(seed32, SEED_LEN, "seed")
    return DerivedKeys(
        k_state=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_STATE, 32)),
        k_index=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_INDEX, 32)),
        k_sql=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_SQL, 32)),
        k_local=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_LOCAL, 32)),
        k_anchor=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_ANCHOR, 32)),
        k_sql_salt=bytes(hkdf_sha256(seed, HKDF_ZERO_SALT, INFO_SQL_SALT, 16)),
    )


def record_key(k_index: bytes, session_id: bytes) -> bytes:
    _require_len(k_index, 32, "k_index")
    sid = _require_len(session_id, 32, "session_id")
    return hmac.new(k_index, RECORD_DOMAIN + sid, hashlib.sha256).digest()


def k_state_record(k_state: bytes, record_key32: bytes) -> bytes:
    return bytes(
        hkdf_sha256(
            _require_len(k_state, 32, "k_state"),
            _require_len(record_key32, 32, "record_key"),
            INFO_STATE_RECORD,
            32,
        )
    )


def k_stage_transition(k_local: bytes, transition_id: bytes) -> bytes:
    return bytes(
        hkdf_sha256(
            _require_len(k_local, 32, "k_local"),
            _require_len(transition_id, 32, "transition_id"),
            INFO_STAGE,
            32,
        )
    )


@dataclass(frozen=True)
class Rvfa1:
    status: Rvfa1Status
    role: int
    record_key: bytes
    session_id: bytes
    anchor_seq: int
    generation: int
    cleared_state_digest: bytes
    cleared_store_revision: int
    transition_id: bytes
    horizon_ms: int
    hmac: bytes = b""

    def prefix_bytes(self) -> bytes:
        if self.role not in (0, 1):
            raise CodecError("role must be 0 or 1")
        if self.anchor_seq < 0 or self.anchor_seq > 0xFFFFFFFFFFFFFFFF:
            raise CodecError("anchor_seq out of range")
        if self.generation < 0 or self.generation > 0xFFFFFFFFFFFFFFFF:
            raise CodecError("generation out of range")
        if self.cleared_store_revision < 0 or self.cleared_store_revision > 0xFFFFFFFFFFFFFFFF:
            raise CodecError("cleared_store_revision out of range")
        if self.horizon_ms < 0 or self.horizon_ms > 0xFFFFFFFFFFFFFFFF:
            raise CodecError("horizon_ms out of range")
        return (
            RVFA1_MAGIC
            + _u16be(RVFA1_SCHEMA)
            + bytes([int(self.status) & 0xFF, self.role & 0xFF])
            + _require_len(self.record_key, 32, "record_key")
            + _require_len(self.session_id, 32, "session_id")
            + _u64be(self.anchor_seq)
            + _u64be(self.generation)
            + _require_len(self.cleared_state_digest, 32, "cleared_state_digest")
            + _u64be(self.cleared_store_revision)
            + _require_len(self.transition_id, 32, "transition_id")
            + _u64be(self.horizon_ms)
        )


def encode_rvfa1(fields: Rvfa1, k_anchor: bytes) -> bytes:
    """Encode RVFA1. Empty/all-zero hmac means compute; any other hmac must match."""
    prefix = fields.prefix_bytes()
    tag = hmac.new(_require_len(k_anchor, 32, "k_anchor"), prefix, hashlib.sha256).digest()
    provided = fields.hmac
    if provided not in (b"", bytes(32)) and provided != tag:
        raise CodecError("provided hmac does not match K_anchor")
    out = prefix + tag
    if len(out) != RVFA1_LEN:
        raise CodecError("RVFA1 length mismatch")
    return out


def decode_rvfa1(raw: bytes, k_anchor: bytes) -> Rvfa1:
    blob = _require_len(raw, RVFA1_LEN, "rvfa1")
    if blob[:8] != RVFA1_MAGIC:
        raise CodecError("bad magic")
    schema = int.from_bytes(blob[8:10], "big")
    if schema != RVFA1_SCHEMA:
        raise CodecError("bad schema")
    try:
        status = Rvfa1Status(blob[10])
    except ValueError as exc:
        raise CodecError("bad status") from exc
    role = blob[11]
    if role not in (0, 1):
        raise CodecError("bad role")
    prefix = blob[:RVFA1_PREFIX_LEN]
    tag = blob[RVFA1_PREFIX_LEN:]
    expected = hmac.new(_require_len(k_anchor, 32, "k_anchor"), prefix, hashlib.sha256).digest()
    if not hmac.compare_digest(tag, expected):
        raise CodecError("bad hmac")
    return Rvfa1(
        status=status,
        role=role,
        record_key=blob[12:44],
        session_id=blob[44:76],
        anchor_seq=int.from_bytes(blob[76:84], "big"),
        generation=int.from_bytes(blob[84:92], "big"),
        cleared_state_digest=blob[92:124],
        cleared_store_revision=int.from_bytes(blob[124:132], "big"),
        transition_id=blob[132:164],
        horizon_ms=int.from_bytes(blob[164:172], "big"),
        hmac=tag,
    )


def identity_key(record_key32: bytes, anchor_seq: int) -> tuple[bytes, int]:
    return (_require_len(record_key32, 32, "record_key"), int(anchor_seq))


def record_invariants_ok(item: Rvfa1, k_index: bytes) -> bool:
    if record_key(k_index, item.session_id) != item.record_key:
        return False
    is_initial = item.anchor_seq == INITIAL_ANCHOR_SEQ
    if item.status == Rvfa1Status.HEAD:
        if item.horizon_ms != 0:
            return False
        if is_initial:
            return item.transition_id == bytes(32)
        return item.transition_id != bytes(32)
    if item.status == Rvfa1Status.DELETING:
        if is_initial or item.horizon_ms == 0 or item.transition_id == bytes(32):
            return False
        return True
    if item.status == Rvfa1Status.TOMBSTONE:
        if is_initial or item.horizon_ms == 0 or item.transition_id != bytes(32):
            return False
        return True
    return False


def status_transition_ok(prev: Optional[Rvfa1Status], nxt: Rvfa1Status) -> bool:
    if prev is None:
        return nxt == Rvfa1Status.HEAD
    if prev == Rvfa1Status.HEAD:
        return nxt in (Rvfa1Status.HEAD, Rvfa1Status.DELETING)
    if prev == Rvfa1Status.DELETING:
        return nxt == Rvfa1Status.TOMBSTONE
    return False


def established_chain_ok(same_record: Sequence[Rvfa1]) -> bool:
    """Existing anchors for one record_key must be contiguous seq=1..N with valid status edges."""
    if not same_record:
        return True
    ordered = sorted(same_record, key=lambda item: item.anchor_seq)
    if ordered[0].anchor_seq != INITIAL_ANCHOR_SEQ:
        return False
    if not status_transition_ok(None, ordered[0].status):
        return False
    for idx, item in enumerate(ordered):
        if item.anchor_seq != INITIAL_ANCHOR_SEQ + idx:
            return False
        if idx > 0 and not status_transition_ok(ordered[idx - 1].status, item.status):
            return False
    return True


def classify_append(
    existing_raw: Sequence[bytes],
    candidate_raw: bytes,
    k_anchor: bytes,
    k_index: bytes,
) -> AppendDecision:
    """Pure append decision with §5.2 binding/status/sequence checks."""
    try:
        candidate = decode_rvfa1(candidate_raw, k_anchor)
        if not record_invariants_ok(candidate, k_index):
            return AppendDecision.CORRUPT
    except CodecError:
        return AppendDecision.CORRUPT

    parsed: list[tuple[bytes, Rvfa1]] = []
    seen: dict[tuple[bytes, int], bytes] = {}
    for raw in existing_raw:
        try:
            item = decode_rvfa1(raw, k_anchor)
            if not record_invariants_ok(item, k_index):
                return AppendDecision.CORRUPT
        except CodecError:
            return AppendDecision.CORRUPT
        key = identity_key(item.record_key, item.anchor_seq)
        if key in seen:
            return AppendDecision.CORRUPT
        if item.record_key != candidate.record_key:
            continue
        if item.session_id != candidate.session_id or item.role != candidate.role:
            return AppendDecision.CORRUPT
        seen[key] = raw
        parsed.append((raw, item))

    same_record = [item for _, item in parsed]
    if not established_chain_ok(same_record):
        return AppendDecision.CORRUPT

    same = seen.get(identity_key(candidate.record_key, candidate.anchor_seq))
    if same is not None:
        if same == candidate_raw:
            return AppendDecision.EXACT_REPLAY
        return AppendDecision.CORRUPT

    if not same_record:
        if candidate.anchor_seq != INITIAL_ANCHOR_SEQ:
            return AppendDecision.CORRUPT
        if not status_transition_ok(None, candidate.status):
            return AppendDecision.CORRUPT
        return AppendDecision.APPENDED

    highest_item = max(same_record, key=lambda item: item.anchor_seq)
    highest = highest_item.anchor_seq
    if highest == 0xFFFFFFFFFFFFFFFF:
        return AppendDecision.CORRUPT
    if candidate.anchor_seq != highest + 1:
        return AppendDecision.CORRUPT
    if not status_transition_ok(highest_item.status, candidate.status):
        return AppendDecision.CORRUPT
    return AppendDecision.APPENDED


def open_rollback_class(
    anchor_generation: int,
    anchor_digest: bytes,
    anchor_revision: int,
    file_generation: int,
    file_digest: bytes,
    file_revision: int,
) -> str:
    """Open classification per durability §7 (digest is not an ordering key)."""
    _require_len(anchor_digest, 32, "anchor_digest")
    _require_len(file_digest, 32, "file_digest")
    if anchor_generation > file_generation:
        return "container_behind_anchor"
    if anchor_generation < file_generation:
        return "anchor_behind_container"
    # Equal generation: digest mismatch is corruption, never ordered.
    if anchor_digest != file_digest:
        return "digest_mismatch"
    if anchor_revision > file_revision:
        return "container_behind_anchor"
    if anchor_revision < file_revision:
        return "anchor_behind_container"
    return "aligned"


__all__ = [
    "APPLE_APP_ID",
    "APPLE_LOGICAL_ROOT",
    "APPLE_ANCHOR_SERVICE",
    "APPLE_SEED_SERVICE",
    "AppendDecision",
    "CodecError",
    "DerivedKeys",
    "ERROR_CODES",
    "INITIAL_ANCHOR_SEQ",
    "LINUX_APPLICATION",
    "LINUX_PROTOCOL",
    "MAX_FULL_BRAID_SESSIONS",
    "RELEASE_HOLD",
    "RVFA1_LEN",
    "Rvfa1",
    "Rvfa1Status",
    "TERMINAL_APP_ID",
    "WINDOWS_CRED_MAX_BLOB",
    "WINDOWS_TARGET_PREFIX",
    "apple_scope_id",
    "classify_append",
    "decode_rvfa1",
    "derive_store_keys",
    "encode_rvfa1",
    "k_stage_transition",
    "k_state_record",
    "open_rollback_class",
    "record_key",
    "scope_id",
    "terminal_scope_id",
]
