"""Full Braid Slice 2 wire codecs (Task 11).

Byte-exact codecs matching Raven Rust (`wire_rvb*.rs`). Lab-only.
RVBE1 schema_rev=2 (admitted_trust). State-machine compute lives in
`full_braid_transition.py`.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from raven_protocol import full_braid_digest as dig

RVBI1_MAGIC = b"RVBI1\0\0\0"
RVBI1_SCHEMA = 1
OP_SEND = 0
OP_RECEIVE = 1

RVBM1_MAGIC = b"RVBM1\0\0\0"
RVBM1_SCHEMA = 1
RVBA1_LEN = 176
BRAID_MAX_AEAD_PLAINTEXT_BYTES = 8192
BRAID_MAX_AEAD_CIPHERTEXT_BYTES = 8208
BRAID_MIN_AEAD_CIPHERTEXT_BYTES = 16
MODE_SEAL_COMPARE = 0
MODE_OPEN = 1

RVBC1_MAGIC = b"RVBC1\0\0\0"
RVBC1_MIN_LEN = 55
RVBC1_MAX_LEN = 8247
RVBC1_HEADER_LEN = 23
RVBC1_MAX_PAYLOAD = RVBC1_MAX_LEN - RVBC1_HEADER_LEN - 32

RVBE1_MAGIC = b"RVBE1\0\0\0"
RVBE1_SCHEMA = 2
RVBE1_SCHEMA_V1_SUPERSEDED = 1
ADMITTED_TRUST_LEN = 128

RVBO1_MAGIC = b"RVBO1\0\0\0"
RVBO1_SCHEMA = 1
EMPTY_RVBO1_LEN = 14

RVCH1_MAGIC = b"RVCH1\0\0\0"
RVCH1_SCHEMA = 1
RVCH1_LEN = 68

BRAID_MAX_PAYLOAD = 8192
BRAID_MAX_CHUNKS_PER_EPOCH = 64
BRAID_MAX_CANONICAL_STATE_BYTES = 262_144
BRAID_MAX_REPLAY_ENTRIES = 64
BRAID_MAX_REPLAY_BYTES = 8192


def _u8(n: int) -> bytes:
    return bytes([n & 0xFF])


def _u16be(n: int) -> bytes:
    return int(n).to_bytes(2, "big")


def _u32be(n: int) -> bytes:
    return int(n).to_bytes(4, "big")


def _u64be(n: int) -> bytes:
    return int(n).to_bytes(8, "big")


class WireReader:
    """Checked big-endian wire reader (mirrors Rust wire_util)."""

    __slots__ = ("_data", "_off")

    def __init__(self, data: bytes, start: int = 0) -> None:
        self._data = data
        self._off = start

    @property
    def off(self) -> int:
        return self._off

    @property
    def remaining(self) -> int:
        return len(self._data) - self._off

    def need(self, n: int) -> None:
        if n < 0 or self._off + n > len(self._data):
            raise ValueError("truncated")

    def read_u8(self) -> int:
        self.need(1)
        v = self._data[self._off]
        self._off += 1
        return v

    def read_u16be(self) -> int:
        self.need(2)
        v = int.from_bytes(self._data[self._off : self._off + 2], "big")
        self._off += 2
        return v

    def read_u32be(self) -> int:
        self.need(4)
        v = int.from_bytes(self._data[self._off : self._off + 4], "big")
        self._off += 4
        return v

    def read_u64be(self) -> int:
        self.need(8)
        v = int.from_bytes(self._data[self._off : self._off + 8], "big")
        self._off += 8
        return v

    def read_bytes(self, n: int) -> bytes:
        self.need(n)
        out = self._data[self._off : self._off + n]
        self._off += n
        return out

    def read_array32(self) -> bytes:
        return self.read_bytes(32)


def expect_magic(data: bytes, magic: bytes) -> None:
    if len(data) < 8 or data[:8] != magic:
        raise ValueError("bad magic")


def reject_trailing(data: bytes, consumed: int) -> None:
    if consumed != len(data):
        raise ValueError("trailing bytes")


@dataclass(frozen=True)
class Rvch1:
    ec_dh_pub: bytes
    ec_pn: int
    ec_n: int
    scka_epoch: int
    scka_pn: int
    scka_n: int
    direction: int


def encode_rvch1(value: Rvch1) -> bytes:
    if len(value.ec_dh_pub) != 32:
        raise ValueError("rvch1 ec_dh_pub")
    if value.direction not in (0, 1):
        raise ValueError("rvch1 direction")
    out = (
        RVCH1_MAGIC
        + _u16be(RVCH1_SCHEMA)
        + value.ec_dh_pub
        + _u32be(value.ec_pn)
        + _u32be(value.ec_n)
        + _u64be(value.scka_epoch)
        + _u32be(value.scka_pn)
        + _u32be(value.scka_n)
        + _u8(value.direction)
        + _u8(0)
    )
    if len(out) != RVCH1_LEN:
        raise AssertionError("rvch1 length")
    return out


def decode_rvch1(data: bytes) -> Rvch1:
    if len(data) != RVCH1_LEN:
        raise ValueError("rvch1 bad length")
    expect_magic(data, RVCH1_MAGIC)
    r = WireReader(data, 8)
    schema = r.read_u16be()
    if schema != RVCH1_SCHEMA:
        raise ValueError("rvch1 bad schema")
    ec_dh_pub = r.read_array32()
    ec_pn = r.read_u32be()
    ec_n = r.read_u32be()
    scka_epoch = r.read_u64be()
    scka_pn = r.read_u32be()
    scka_n = r.read_u32be()
    direction = r.read_u8()
    reserved0 = r.read_u8()
    if reserved0 != 0:
        raise ValueError("rvch1 reserved0")
    reject_trailing(data, r.off)
    return Rvch1(ec_dh_pub, ec_pn, ec_n, scka_epoch, scka_pn, scka_n, direction)


@dataclass(frozen=True)
class AdmittedTrustEvidence:
    initiator_cert_digest: bytes
    initiator_identity_pub: bytes
    responder_cert_digest: bytes
    responder_identity_pub: bytes

    @staticmethod
    def lab_default() -> "AdmittedTrustEvidence":
        return AdmittedTrustEvidence(
            initiator_cert_digest=bytes([0x21]) * 32,
            initiator_identity_pub=bytes([0x22]) * 32,
            responder_cert_digest=bytes([0x31]) * 32,
            responder_identity_pub=bytes([0x32]) * 32,
        )

    def encode(self) -> bytes:
        out = (
            self.initiator_cert_digest
            + self.initiator_identity_pub
            + self.responder_cert_digest
            + self.responder_identity_pub
        )
        if len(out) != ADMITTED_TRUST_LEN:
            raise ValueError("admitted_trust must be 128 bytes")
        return out


@dataclass
class Rvbm1:
    needs_aead: int = 0
    ec_mk_oracle_len: int = 0
    ec_mk_oracle: bytes = bytes(32)
    aad: bytes = b""
    mode: int = 0
    body: bytes = b""
    expected_ct: Optional[bytes] = None

    @staticmethod
    def no_aead() -> "Rvbm1":
        return Rvbm1()


def _validate_rvbm1_contract(body: Rvbm1) -> None:
    if body.needs_aead > 1:
        raise ValueError("rvbm1 needs_aead")
    if body.needs_aead == 0:
        if (
            body.ec_mk_oracle_len != 0
            or body.ec_mk_oracle != bytes(32)
            or body.aad
            or body.mode != 0
            or body.body
            or body.expected_ct is not None
        ):
            raise ValueError("rvbm1 needs_aead=0 contract")
    else:
        if body.ec_mk_oracle_len not in (0, 32):
            raise ValueError("rvbm1 oracle_len")
        if len(body.aad) != RVBA1_LEN:
            raise ValueError("rvbm1 aad_len")
        if body.mode > 1:
            raise ValueError("rvbm1 mode")
        if body.mode == MODE_SEAL_COMPARE:
            if len(body.body) > BRAID_MAX_AEAD_PLAINTEXT_BYTES:
                raise ValueError("rvbm1 body_len")
            if body.expected_ct is None:
                raise ValueError("rvbm1 missing expected_ct")
            if len(body.expected_ct) != len(body.body) + 16:
                raise ValueError("rvbm1 expected_ct_len")
        elif body.mode == MODE_OPEN:
            if not (
                BRAID_MIN_AEAD_CIPHERTEXT_BYTES
                <= len(body.body)
                <= BRAID_MAX_AEAD_CIPHERTEXT_BYTES
            ):
                raise ValueError("rvbm1 body_len")
            if body.expected_ct is not None:
                raise ValueError("rvbm1 unexpected expected_ct")
        else:
            raise ValueError("rvbm1 mode")


def _encode_rvbm1_wire(body: Rvbm1) -> bytes:
    _validate_rvbm1_contract(body)
    out = bytearray()
    out += RVBM1_MAGIC
    out += _u16be(RVBM1_SCHEMA)
    out += _u8(body.needs_aead)
    out += _u8(0)
    out += _u16be(body.ec_mk_oracle_len)
    out += body.ec_mk_oracle
    out += _u16be(len(body.aad))
    out += body.aad
    out += _u8(body.mode)
    out += _u32be(len(body.body))
    out += body.body
    if body.needs_aead == 1 and body.mode == MODE_SEAL_COMPARE:
        assert body.expected_ct is not None
        out += _u32be(len(body.expected_ct))
        out += body.expected_ct
    return bytes(out)


def encode_rvbm1(body: Rvbm1) -> bytes:
    return _encode_rvbm1_wire(body)


def decode_rvbm1(data: bytes) -> Rvbm1:
    expect_magic(data, RVBM1_MAGIC)
    r = WireReader(data, 8)
    schema = r.read_u16be()
    if schema != RVBM1_SCHEMA:
        raise ValueError("rvbm1 bad schema")
    needs = r.read_u8()
    reserved0 = r.read_u8()
    if reserved0 != 0:
        raise ValueError("rvbm1 reserved0")
    oracle_len = r.read_u16be()
    oracle = r.read_bytes(32)
    aad_len = r.read_u16be()
    aad = r.read_bytes(aad_len)
    mode = r.read_u8()
    body_len = r.read_u32be()
    body = r.read_bytes(body_len)
    expected_ct = None
    if needs == 1 and mode == MODE_SEAL_COMPARE:
        ct_len = r.read_u32be()
        expected_ct = r.read_bytes(ct_len)
    reject_trailing(data, r.off)
    parsed = Rvbm1(
        needs_aead=needs,
        ec_mk_oracle_len=oracle_len,
        ec_mk_oracle=oracle,
        aad=aad,
        mode=mode,
        body=body,
        expected_ct=expected_ct,
    )
    _validate_rvbm1_contract(parsed)
    return parsed


@dataclass
class Rvbc1:
    epoch: int
    chunk_type: int
    index: int
    payload: bytes
    binding: bytes

    def encoded_len(self) -> int:
        return RVBC1_HEADER_LEN + len(self.payload) + 32


def encode_rvbc1(chunk: Rvbc1) -> bytes:
    if len(chunk.payload) > RVBC1_MAX_PAYLOAD:
        raise ValueError("rvbc1 payload too large")
    total = chunk.encoded_len()
    if not (RVBC1_MIN_LEN <= total <= RVBC1_MAX_LEN):
        raise ValueError("rvbc1 length out of range")
    if len(chunk.binding) != 32:
        raise ValueError("binding must be 32")
    return (
        RVBC1_MAGIC
        + _u64be(chunk.epoch)
        + _u8(chunk.chunk_type)
        + _u32be(chunk.index)
        + _u16be(len(chunk.payload))
        + chunk.payload
        + chunk.binding
    )


def decode_rvbc1(data: bytes) -> Rvbc1:
    if not (RVBC1_MIN_LEN <= len(data) <= RVBC1_MAX_LEN):
        raise ValueError("rvbc1 length out of range")
    expect_magic(data, RVBC1_MAGIC)
    r = WireReader(data, 8)
    epoch = r.read_u64be()
    chunk_type = r.read_u8()
    index = r.read_u32be()
    plen = r.read_u16be()
    payload = r.read_bytes(plen)
    binding = r.read_array32()
    reject_trailing(data, r.off)
    return Rvbc1(epoch, chunk_type, index, payload, binding)


@dataclass
class Rvbi1:
    op: int
    direction: int
    ch: Optional[Rvch1] = None
    expected_ch: Optional[Rvch1] = None
    object_digest: Optional[bytes] = None
    frame: Optional[bytes] = None
    mutation: Rvbm1 = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.mutation is None:
            self.mutation = Rvbm1.no_aead()


def _validate_rvbi1_contract(inp: Rvbi1) -> None:
    if inp.op > OP_RECEIVE:
        raise ValueError("rvbi1 op")
    if inp.op == OP_SEND:
        if (
            inp.ch is not None
            or inp.expected_ch is not None
            or inp.object_digest is not None
            or inp.frame is not None
        ):
            raise ValueError("rvbi1 send field contract")
    elif inp.op == OP_RECEIVE:
        if inp.frame is None:
            raise ValueError("rvbi1 receive missing frame")
        needs_aead = inp.mutation.needs_aead
        if needs_aead == 1:
            if inp.ch is None or inp.object_digest is None:
                raise ValueError("rvbi1 receive aead contract")
        elif inp.ch is not None or inp.object_digest is None:
            raise ValueError("rvbi1 receive no-aead contract")


def encode_rvbi1(inp: Rvbi1) -> bytes:
    _validate_rvbi1_contract(inp)

    out = bytearray()
    out += RVBI1_MAGIC
    out += _u16be(RVBI1_SCHEMA)
    out += _u8(inp.op)
    out += _u8(inp.direction)
    out += _u16be(0)  # reserved0
    if inp.ch is None:
        out += _u8(0) + _u8(0)
    else:
        out += _u8(1) + _u8(0)
        out += encode_rvch1(inp.ch)
    if inp.expected_ch is None:
        out += _u8(0) + _u8(0)
    else:
        out += _u8(1) + _u8(0)
        out += encode_rvch1(inp.expected_ch)
    if inp.object_digest is None:
        out += _u8(0) + _u8(0)
    else:
        if len(inp.object_digest) != 32:
            raise ValueError("rvbi1 object_digest")
        out += _u8(1) + _u8(0)
        out += inp.object_digest
    if inp.op == OP_RECEIVE:
        assert inp.frame is not None
        decode_rvbc1(inp.frame)
        out += _u32be(len(inp.frame))
        out += inp.frame
    out += encode_rvbm1(inp.mutation)
    return bytes(out)


def decode_rvbi1(data: bytes) -> Rvbi1:
    expect_magic(data, RVBI1_MAGIC)
    r = WireReader(data, 8)
    schema = r.read_u16be()
    if schema != RVBI1_SCHEMA:
        raise ValueError("rvbi1 bad schema")
    op = r.read_u8()
    direction = r.read_u8()
    reserved0 = r.read_u16be()
    if reserved0 != 0:
        raise ValueError("rvbi1 reserved0")

    ch_present = r.read_u8()
    reserved1 = r.read_u8()
    if reserved1 != 0:
        raise ValueError("rvbi1 reserved1")
    if ch_present == 1:
        ch = decode_rvch1(r.read_bytes(RVCH1_LEN))
    elif ch_present == 0:
        ch = None
    else:
        raise ValueError("rvbi1 ch_present")

    expected_present = r.read_u8()
    reserved2 = r.read_u8()
    if reserved2 != 0:
        raise ValueError("rvbi1 reserved2")
    if expected_present == 1:
        expected_ch = decode_rvch1(r.read_bytes(RVCH1_LEN))
    elif expected_present == 0:
        expected_ch = None
    else:
        raise ValueError("rvbi1 expected_ch_present")

    od_present = r.read_u8()
    reserved3 = r.read_u8()
    if reserved3 != 0:
        raise ValueError("rvbi1 reserved3")
    if od_present == 1:
        object_digest = r.read_array32()
    elif od_present == 0:
        object_digest = None
    else:
        raise ValueError("rvbi1 object_digest_present")

    frame = None
    if op == OP_RECEIVE:
        frame_len = r.read_u32be()
        if frame_len == 0:
            raise ValueError("rvbi1 frame_len zero")
        if not (RVBC1_MIN_LEN <= frame_len <= RVBC1_MAX_LEN):
            raise ValueError("rvbi1 frame_len range")
        frame_bytes = r.read_bytes(frame_len)
        decode_rvbc1(frame_bytes)
        frame = frame_bytes

    mutation_off = r.off
    mutation = decode_rvbm1(data[mutation_off:])
    mutation_len = len(_encode_rvbm1_wire(mutation))
    r._off = mutation_off + mutation_len  # mirror Rust off += mutation_len
    reject_trailing(data, r.off)

    inp = Rvbi1(
        op=op,
        direction=direction,
        ch=ch,
        expected_ch=expected_ch,
        object_digest=object_digest,
        frame=frame,
        mutation=mutation,
    )
    _validate_rvbi1_contract(inp)
    return inp


@dataclass
class Rvbe1:
    clock: int
    cap_payload: int = BRAID_MAX_PAYLOAD
    cap_chunks: int = BRAID_MAX_CHUNKS_PER_EPOCH
    cap_state: int = BRAID_MAX_CANONICAL_STATE_BYTES
    cap_replay_entries: int = BRAID_MAX_REPLAY_ENTRIES
    cap_replay_bytes: int = BRAID_MAX_REPLAY_BYTES
    keygen_seed: bytes = b""
    encaps_coins: bytes = b""
    ec_dh_seed: bytes = b""
    admitted_trust: Optional[AdmittedTrustEvidence] = None

    @staticmethod
    def default_caps(clock: int) -> "Rvbe1":
        return Rvbe1(clock=clock)

    def with_lab_trust(self) -> "Rvbe1":
        self.admitted_trust = AdmittedTrustEvidence.lab_default()
        return self


def _validate_rvbe1_seed_lens(env: Rvbe1) -> None:
    kg = len(env.keygen_seed)
    if kg not in (0, 64):
        raise ValueError("rvbe1 keygen_seed len")
    enc = len(env.encaps_coins)
    if enc not in (0, 32):
        raise ValueError("rvbe1 encaps_coins len")
    dh = len(env.ec_dh_seed)
    if dh not in (0, 32):
        raise ValueError("rvbe1 ec_dh_seed len")


def _validate_rvbe1_caps(env: Rvbe1) -> None:
    if env.cap_payload > BRAID_MAX_PAYLOAD:
        raise ValueError("rvbe1 cap_payload")
    if env.cap_chunks > BRAID_MAX_CHUNKS_PER_EPOCH:
        raise ValueError("rvbe1 cap_chunks")
    if env.cap_state > BRAID_MAX_CANONICAL_STATE_BYTES:
        raise ValueError("rvbe1 cap_state")
    if env.cap_replay_entries > BRAID_MAX_REPLAY_ENTRIES:
        raise ValueError("rvbe1 cap_replay_entries")
    if env.cap_replay_bytes > BRAID_MAX_REPLAY_BYTES:
        raise ValueError("rvbe1 cap_replay_bytes")
    _validate_rvbe1_seed_lens(env)


def encode_rvbe1(env: Rvbe1) -> bytes:
    _validate_rvbe1_caps(env)
    out = bytearray()
    out += RVBE1_MAGIC
    out += _u16be(RVBE1_SCHEMA)
    out += _u64be(env.clock)
    out += _u32be(env.cap_payload)
    out += _u32be(env.cap_chunks)
    out += _u32be(env.cap_state)
    out += _u32be(env.cap_replay_entries)
    out += _u32be(env.cap_replay_bytes)
    out += _u16be(len(env.keygen_seed))
    out += env.keygen_seed
    out += _u16be(len(env.encaps_coins))
    out += env.encaps_coins
    out += _u16be(len(env.ec_dh_seed))
    out += env.ec_dh_seed
    if env.admitted_trust is None:
        out += _u16be(0)
    else:
        trust = env.admitted_trust.encode()
        out += _u16be(len(trust))
        out += trust
    out += _u32be(0)  # reserved_tail
    return bytes(out)


def decode_rvbe1(data: bytes) -> Rvbe1:
    expect_magic(data, RVBE1_MAGIC)
    r = WireReader(data, 8)
    schema = r.read_u16be()
    if schema != RVBE1_SCHEMA:
        raise ValueError("rvbe1 bad schema")
    clock = r.read_u64be()
    cap_payload = r.read_u32be()
    cap_chunks = r.read_u32be()
    cap_state = r.read_u32be()
    cap_replay_entries = r.read_u32be()
    cap_replay_bytes = r.read_u32be()
    keygen_len = r.read_u16be()
    keygen_seed = r.read_bytes(keygen_len)
    encaps_len = r.read_u16be()
    encaps_coins = r.read_bytes(encaps_len)
    dh_len = r.read_u16be()
    ec_dh_seed = r.read_bytes(dh_len)
    trust_len = r.read_u16be()
    admitted_trust = None
    if trust_len == 0:
        pass
    elif trust_len == ADMITTED_TRUST_LEN:
        raw = r.read_bytes(ADMITTED_TRUST_LEN)
        admitted_trust = AdmittedTrustEvidence(
            initiator_cert_digest=raw[0:32],
            initiator_identity_pub=raw[32:64],
            responder_cert_digest=raw[64:96],
            responder_identity_pub=raw[96:128],
        )
    else:
        raise ValueError("rvbe1 admitted_trust_len")
    reserved_tail = r.read_u32be()
    if reserved_tail != 0:
        raise ValueError("rvbe1 reserved_tail")
    reject_trailing(data, r.off)

    env = Rvbe1(
        clock=clock,
        cap_payload=cap_payload,
        cap_chunks=cap_chunks,
        cap_state=cap_state,
        cap_replay_entries=cap_replay_entries,
        cap_replay_bytes=cap_replay_bytes,
        keygen_seed=keygen_seed,
        encaps_coins=encaps_coins,
        ec_dh_seed=ec_dh_seed,
        admitted_trust=admitted_trust,
    )
    _validate_rvbe1_caps(env)
    return env


def encode_empty_rvbo1() -> bytes:
    out = RVBO1_MAGIC + _u16be(RVBO1_SCHEMA) + _u16be(0) + _u8(0) + _u8(0)
    if len(out) != EMPTY_RVBO1_LEN:
        raise AssertionError("empty rvbo1 len")
    return out


def encode_superseded_rvbe1_schema1(clock: int = 0) -> bytes:
    """Pre-vector schema-1 layout (no admitted_trust) — MUST reject under schema=2."""
    out = bytearray()
    out += RVBE1_MAGIC
    out += _u16be(RVBE1_SCHEMA_V1_SUPERSEDED)
    out += _u64be(clock)
    out += _u32be(BRAID_MAX_PAYLOAD)
    out += _u32be(BRAID_MAX_CHUNKS_PER_EPOCH)
    out += _u32be(BRAID_MAX_CANONICAL_STATE_BYTES)
    out += _u32be(BRAID_MAX_REPLAY_ENTRIES)
    out += _u32be(BRAID_MAX_REPLAY_BYTES)
    out += _u16be(0)
    out += _u16be(0)
    out += _u16be(0)
    out += _u32be(0)
    return bytes(out)


def make_receive_frame(
    *,
    session_id: bytes,
    direction: int = 0,
    epoch: int = 1,
    chunk_type: int = 1,
    index: int = 0,
    payload: Optional[bytes] = None,
) -> bytes:
    if payload is None:
        payload = bytes(32)
    binding = dig.binding_digest(direction, epoch, chunk_type, index, payload, session_id)
    return encode_rvbc1(
        Rvbc1(
            epoch=epoch,
            chunk_type=chunk_type,
            index=index,
            payload=payload,
            binding=binding,
        )
    )
