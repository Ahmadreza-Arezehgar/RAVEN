from raven_protocol import address

ALICE_ED_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

def test_address_roundtrip():
    a = address.encode(ALICE_ED_PUB)
    assert a.startswith("rvn1")
    pub_hash, version = address.decode(a)
    assert version == 1
    assert len(pub_hash) == 20

def test_address_is_deterministic():
    assert address.encode(ALICE_ED_PUB) == address.encode(ALICE_ED_PUB)

def test_corrupted_address_rejected():
    a = address.encode(ALICE_ED_PUB)
    bad = a[:-1] + ("q" if a[-1] != "q" else "p")
    assert address.decode(bad) is None

def test_display_grouping_is_reversible():
    a = address.encode(ALICE_ED_PUB)
    disp = address.to_display(a)
    assert disp.startswith("rvn1:")
    assert address.from_display(disp) == a
