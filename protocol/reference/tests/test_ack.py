from raven_protocol import ack
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
BOB_ED_PRIV = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")

def test_ack_signing_bytes_bind_status():
    a = ack.Ack(acked_message_id=bytes(16), status=1, ack_nonce=(7).to_bytes(12,"big"), created_at=1700000000000)
    a2 = ack.Ack(acked_message_id=bytes(16), status=2, ack_nonce=(7).to_bytes(12,"big"), created_at=1700000000000)
    assert ack.signing_bytes(a) != ack.signing_bytes(a2)

def test_ack_sign_verify():
    a = ack.Ack(bytes(16), 1, (7).to_bytes(12,"big"), 1700000000000)
    priv = Ed25519PrivateKey.from_private_bytes(BOB_ED_PRIV)
    sig = priv.sign(ack.signing_bytes(a))
    assert ack.verify(a, sig, priv.public_key().public_bytes_raw())
