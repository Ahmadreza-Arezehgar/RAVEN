"""Schema checks for mlkem768_incremental_encaps_001.json (no live ML-KEM)."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from raven_protocol import mlkem768_incremental_check as mic

REPO = Path(__file__).resolve().parents[3]
VEC = REPO / "shared-vectors/rvn1/atsam"
FIXTURE = "mlkem768_incremental_encaps_001.json"


def _load(name: str = FIXTURE) -> dict:
    return json.loads((VEC / name).read_text())


def test_frozen_fixture_passes():
    mic.check_fixture(_load())


def test_accepts_optional_metadata():
    v = _load()
    assert v["vector_id"] == "mlkem768_incremental_encaps_001"
    assert v["lab_only"] is True
    assert "notes" in v
    mic.check_fixture(v)


def test_rejects_missing_required_field():
    v = _load()
    del v["seed_hex"]
    with pytest.raises(ValueError, match="seed_hex"):
        mic.check_fixture(v)


def test_rejects_bad_hex():
    v = _load()
    v["coins_hex"] = "not-hex"
    with pytest.raises(ValueError, match="coins_hex"):
        mic.check_fixture(v)


@pytest.mark.parametrize(
    "field,expected_len",
    [
        ("seed_hex", 64),
        ("coins_hex", 32),
        ("dk_hex", 2400),
        ("header_hex", 64),
        ("ek_vector_hex", 1152),
        ("fips_ek_hex", 1184),
        ("encaps_state_hex", 2080),
        ("ct1_hex", 960),
        ("ct2_hex", 128),
        ("ss_hex", 32),
        ("atomic_libcrux_ct_hex", 1088),
        ("atomic_libcrux_ss_hex", 32),
        ("atomic_rustcrypto_ct_hex", 1088),
        ("atomic_rustcrypto_ss_hex", 32),
    ],
)
def test_rejects_wrong_length(field: str, expected_len: int):
    v = _load()
    short = bytes(range(min(expected_len, 16))).hex()
    v[field] = short
    with pytest.raises(ValueError, match=field):
        mic.check_fixture(v)


def test_rejects_bad_header_hash():
    v = _load()
    header = bytearray.fromhex(v["header_hex"])
    header[-1] ^= 0x01
    v["header_hex"] = header.hex()
    with pytest.raises(ValueError, match="fips_ek_hex|header_hex"):
        mic.check_fixture(v)


def test_rejects_tampered_vector_with_valid_rho():
    v = _load()
    vector = bytearray.fromhex(v["ek_vector_hex"])
    vector[0] ^= 0x01
    v["ek_vector_hex"] = vector.hex()
    with pytest.raises(ValueError, match="fips_ek_hex|header_hex"):
        mic.check_fixture(v)


def test_rejects_mismatched_fips_ek():
    v = _load()
    fips = bytearray.fromhex(v["fips_ek_hex"])
    fips[0] ^= 0x01
    v["fips_ek_hex"] = fips.hex()
    with pytest.raises(ValueError, match="fips_ek_hex"):
        mic.check_fixture(v)


def test_rejects_mismatched_atomic_libcrux_ct():
    v = _load()
    ct = bytearray.fromhex(v["atomic_libcrux_ct_hex"])
    ct[0] ^= 0x01
    v["atomic_libcrux_ct_hex"] = ct.hex()
    with pytest.raises(ValueError, match="atomic_libcrux_ct_hex"):
        mic.check_fixture(v)


def test_rejects_mismatched_atomic_rustcrypto_ss():
    v = _load()
    ss = bytearray.fromhex(v["atomic_rustcrypto_ss_hex"])
    ss[0] ^= 0x01
    v["atomic_rustcrypto_ss_hex"] = ss.hex()
    with pytest.raises(ValueError, match="atomic_rustcrypto_ss_hex"):
        mic.check_fixture(v)


def test_check_fixture_returns_decoded_fields():
    out = mic.check_fixture(_load())
    assert out["seed"] == bytes(range(64))
    assert out["coins"] == bytes([0x07] * 32)
    assert len(out["dk"]) == 2400
    assert len(out["header"]) == 64
    assert len(out["ek_vector"]) == 1152
    assert len(out["encaps_state"]) == 2080
    assert len(out["ct1"]) == 960
    assert len(out["ct2"]) == 128
    assert len(out["ss"]) == 32


def test_check_fixture_does_not_mutate_input():
    v = _load()
    original = copy.deepcopy(v)
    mic.check_fixture(v)
    assert v == original
