from raven_protocol import capabilities, address
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ALICE_ED_PRIV = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
BOB_ED_PUB = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")

def test_capabilities_sign_verify_and_downgrade_binding():
    c = capabilities.Capabilities(identity_address=address.encode(ALICE_ED_PUB),
                                  capability_bits=0b1111, expires_at=1700604800000)
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    c.signature = priv.sign(capabilities.signing_bytes(c))
    assert capabilities.verify(c, ALICE_ED_PUB)
    # Flipping an advertised capability bit invalidates the signature (downgrade defense).
    c.capability_bits = 0b0001
    assert not capabilities.verify(c, ALICE_ED_PUB)

def test_capabilities_wrong_signer_rejected():
    c = capabilities.Capabilities(identity_address=address.encode(ALICE_ED_PUB),
                                  capability_bits=0b1111, expires_at=1700604800000)
    c.signature = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(capabilities.signing_bytes(c))
    assert not capabilities.verify(c, BOB_ED_PUB)
