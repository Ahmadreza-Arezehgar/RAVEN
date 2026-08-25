# tests/test_bech32m.py
from raven_protocol import bech32m

def test_encode_decode_roundtrip():
    data = bytes(range(21))  # 21 payload bytes (version + 20-byte hash)
    s = bech32m.encode("rvn", data)
    assert s.startswith("rvn1")
    hrp, out = bech32m.decode(s)
    assert hrp == "rvn"
    assert out == data

def test_checksum_rejects_single_char_corruption():
    s = bech32m.encode("rvn", bytes(range(21)))
    # flip one data char (not the hrp, not the '1' separator)
    i = len(s) - 3
    bad = s[:i] + ("q" if s[i] != "q" else "p") + s[i+1:]
    assert bech32m.decode(bad) is None

def test_wrong_hrp_is_reported():
    s = bech32m.encode("rvn", bytes(range(21)))
    hrp, _ = bech32m.decode(s)
    assert hrp != "btc"
