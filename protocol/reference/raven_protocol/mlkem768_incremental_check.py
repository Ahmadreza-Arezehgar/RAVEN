"""Schema and layout checks for ML-KEM-768 incremental encapsulation vectors.

Validates shared-vectors/rvn1/atsam/mlkem768_incremental_encaps_001.json without
calling Encaps/Decaps or any ML-KEM library — lengths, FIPS layout, SHA3 header
binding, and equality of fixture atomic-oracle fields.
"""

from __future__ import annotations

from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.hashes import SHA3_256

SEED_LEN = 64
COINS_LEN = 32
DK_LEN = 2400
HEADER_LEN = 64
EK_VECTOR_LEN = 1152
FIPS_EK_LEN = 1184
ENCAPS_STATE_LEN = 2080
CT1_LEN = 960
CT2_LEN = 128
FIPS_CT_LEN = CT1_LEN + CT2_LEN
SS_LEN = 32

_REQUIRED_HEX_FIELDS: tuple[tuple[str, int], ...] = (
    ("seed_hex", SEED_LEN),
    ("coins_hex", COINS_LEN),
    ("dk_hex", DK_LEN),
    ("header_hex", HEADER_LEN),
    ("ek_vector_hex", EK_VECTOR_LEN),
    ("fips_ek_hex", FIPS_EK_LEN),
    ("encaps_state_hex", ENCAPS_STATE_LEN),
    ("ct1_hex", CT1_LEN),
    ("ct2_hex", CT2_LEN),
    ("ss_hex", SS_LEN),
    ("atomic_libcrux_ct_hex", FIPS_CT_LEN),
    ("atomic_libcrux_ss_hex", SS_LEN),
    ("atomic_rustcrypto_ct_hex", FIPS_CT_LEN),
    ("atomic_rustcrypto_ss_hex", SS_LEN),
)


def _decode_hex_field(obj: dict[str, Any], field: str, length: int) -> bytes:
    if field not in obj:
        raise ValueError(f"missing required field {field}")
    raw = obj[field]
    if not isinstance(raw, str):
        raise ValueError(f"{field} must be a hex string")
    try:
        decoded = bytes.fromhex(raw)
    except ValueError as exc:
        raise ValueError(f"{field} must be valid hex") from exc
    if len(decoded) != length:
        raise ValueError(f"{field} must decode to exactly {length} bytes")
    return decoded


def _sha3_256(data: bytes) -> bytes:
    digest = hashes.Hash(SHA3_256())
    digest.update(data)
    return digest.finalize()


def _validate_header_layout(header: bytes, ek_vector: bytes, fips_ek: bytes) -> None:
    rho = header[:32]
    computed_fips = ek_vector + rho
    if fips_ek != computed_fips:
        raise ValueError("fips_ek_hex must equal ek_vector || rho (header[0:32])")
    expected_h = _sha3_256(fips_ek)
    if header[32:] != expected_h:
        raise ValueError(
            "header_hex: expected rho || SHA3-256(fips_ek) layout"
        )


def check_fixture(obj: dict[str, Any]) -> dict[str, bytes]:
    """Validate fixture schema, lengths, FIPS layout, and atomic oracle fields.

    Optional keys ``vector_id``, ``lab_only``, and ``notes`` are ignored.
    Returns decoded byte fields for downstream tests.
    """
    decoded: dict[str, bytes] = {}
    for field, length in _REQUIRED_HEX_FIELDS:
        decoded[field.removesuffix("_hex")] = _decode_hex_field(obj, field, length)

    _validate_header_layout(
        decoded["header"], decoded["ek_vector"], decoded["fips_ek"]
    )

    computed_ct = decoded["ct1"] + decoded["ct2"]
    if decoded["atomic_libcrux_ct"] != computed_ct:
        raise ValueError("atomic_libcrux_ct_hex must equal ct1 || ct2")
    if decoded["atomic_rustcrypto_ct"] != computed_ct:
        raise ValueError("atomic_rustcrypto_ct_hex must equal ct1 || ct2")
    if decoded["atomic_libcrux_ss"] != decoded["ss"]:
        raise ValueError("atomic_libcrux_ss_hex must equal ss_hex")
    if decoded["atomic_rustcrypto_ss"] != decoded["ss"]:
        raise ValueError("atomic_rustcrypto_ss_hex must equal ss_hex")

    return decoded
