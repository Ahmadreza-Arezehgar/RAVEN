from raven_protocol import fingerprint

ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
# dave: SHA-256(edPub)[:9] base64 is "NN72hvSxN/7W" — it contains a '/', so the
# strip step shortens it to 11 chars and the last group has only 3. This is the
# ~31% branch a port would silently diverge on if it used base64url or truncated
# to 12 BEFORE stripping. Lock it with an explicit value.
DAVE_ED_PUB = bytes.fromhex("e61a185bcef2613a6c7cb79763ce945d3b245d76114dd440bcf5f2dc1aa57057")

def test_canonical_device_fingerprint_alice_clean_branch():
    # Standard base64 of SHA256[:9] with no '+'/'/': full 12 chars, three groups of 4.
    assert fingerprint.device_fingerprint_v1(ALICE_ED_PUB) == "If4x-36FU-omFi"

def test_canonical_device_fingerprint_dave_strip_branch():
    # '/' stripped -> 11 chars -> last group is 3. Ports must strip '+'/'/' AFTER
    # standard-base64 encoding and group the REMAINING chars, not use base64url.
    assert fingerprint.device_fingerprint_v1(DAVE_ED_PUB) == "NN72-hvSx-N7W"

def test_meshv1_hex_fingerprint_is_alice_known_value():
    # Locks the deprecated MeshV1 scheme against its own frozen v1 vector.
    assert fingerprint.mesh_v1_hex_fingerprint(ALICE_ED_PUB) == "21FE-31DF-A154"
