from raven_protocol import device_cert
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
ALICE_ED_PRIV = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
BOB_ED_PUB = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
BOB_X_PUB = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")

def test_device_cert_signed_by_user_identity():
    c = device_cert.DeviceCert(device_ed_pub=BOB_ED_PUB, device_x_pub=BOB_X_PUB,
                               device_id="bob-device-1", not_before=1700000000000,
                               not_after=1731536000000, capabilities=0b111)
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    c.signature = priv.sign(device_cert.signing_bytes(c))
    assert device_cert.verify(c, user_identity_ed_pub=ALICE_ED_PUB)
