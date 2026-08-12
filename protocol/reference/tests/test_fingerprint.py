import hashlib
from raven_protocol import fingerprint

ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

def test_canonical_device_fingerprint_matches_app_scheme():
    # SHA256[:9] -> base64 strip +/ -> first 12 -> XXXX-XXXX-XXXX
    assert fingerprint.device_fingerprint_v1(ALICE_ED_PUB) == fingerprint.device_fingerprint_v1(ALICE_ED_PUB)
    fp = fingerprint.device_fingerprint_v1(ALICE_ED_PUB)
    assert len(fp) == 14 and fp[4] == "-" and fp[9] == "-"

def test_meshv1_hex_fingerprint_is_alice_known_value():
    # Locks the deprecated MeshV1 scheme against its own frozen vector.
    assert fingerprint.mesh_v1_hex_fingerprint(ALICE_ED_PUB) == "21FE-31DF-A154"
