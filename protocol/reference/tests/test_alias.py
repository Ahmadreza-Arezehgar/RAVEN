from raven_protocol import alias, address
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
ALICE_ED_PRIV = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

def test_alias_sign_verify_and_sequence_binding():
    addr = address.encode(ALICE_ED_PUB)
    r = alias.AliasRecord(alias="ahmad", identity_address=addr, sequence=42, expires_at=1700086400000)
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    r.signature = priv.sign(alias.signing_bytes(r))
    assert alias.verify(r, ALICE_ED_PUB)
    r.sequence = 43  # bumping sequence invalidates the old signature
    assert not alias.verify(r, ALICE_ED_PUB)
