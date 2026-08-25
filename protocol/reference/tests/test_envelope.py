# tests/test_envelope.py
from raven_protocol import envelope
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ALICE_ED_PRIV = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

def _env():
    return envelope.Envelope(
        env_type=1, flags=0,
        message_id=bytes(16), routing_tag=bytes(range(16)),
        dest_device_hint=0xAABBCCDD, created_at=1700000000000, expires_at=1700086400000,
        hop_limit=8, replication_budget=3, anti_replay_nonce=(1).to_bytes(12, "big"),
        ratchet_header_ciphertext=b"hdr", message_ciphertext=b"RVNS1....body",
        # Structural decode requires the canonical Ed25519 signature width;
        # cryptographic validity is tested separately below.
        sender_authentication=bytes(64),
    )

def test_pack_unpack_roundtrip():
    e = _env()
    raw = envelope.pack(e)
    back = envelope.unpack(raw)
    assert back.message_ciphertext == e.message_ciphertext
    assert back.routing_tag == e.routing_tag
    assert raw[:4] == b"RVN1"

def test_signing_bytes_zero_mutable_fields():
    e = _env()
    sb = envelope.signing_bytes(e)
    e2 = _env(); e2.hop_limit = 1; e2.replication_budget = 0; e2.dest_device_hint = 0
    assert envelope.signing_bytes(e2) == sb  # mutable-field changes do not affect signature

def test_sign_verify():
    e = _env()
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    e.sender_authentication = priv.sign(envelope.signing_bytes(e))
    assert envelope.verify(e, priv.public_key().public_bytes_raw())

def test_tampered_body_fails_verify():
    e = _env()
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    e.sender_authentication = priv.sign(envelope.signing_bytes(e))
    e.message_ciphertext = b"RVNS1....TAMPER"
    assert not envelope.verify(e, priv.public_key().public_bytes_raw())

def test_unpack_rejects_bad_magic():
    raw = bytearray(envelope.pack(_env())); raw[0] = 0
    assert envelope.unpack(bytes(raw)) is None

def test_unpack_rejects_unknown_type_reserved_flags_and_bad_time():
    e = _env()
    raw = bytearray(envelope.pack(e))

    unknown = bytearray(raw); unknown[5] = 5
    assert envelope.unpack(bytes(unknown)) is None

    reserved = bytearray(raw); reserved[6:8] = (0x0004).to_bytes(2, "big")
    assert envelope.unpack(bytes(reserved)) is None

    bad_time = bytearray(raw); bad_time[56:64] = e.created_at.to_bytes(8, "big")
    assert envelope.unpack(bytes(bad_time)) is None

def test_unpack_requires_signature_width_and_bounded_lengths():
    raw = bytearray(envelope.pack(_env()))

    bad_auth = bytearray(raw); bad_auth[84:86] = (63).to_bytes(2, "big")
    assert envelope.unpack(bytes(bad_auth)) is None

    impossible_body = bytearray(raw); impossible_body[80:84] = (0xFFFFFFFF).to_bytes(4, "big")
    assert envelope.unpack(bytes(impossible_body)) is None

    assert envelope.unpack(bytes(envelope.MAX_WIRE_ENVELOPE_BYTES + 1)) is None
