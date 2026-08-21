"""Task 0B.1 KATs — protected seed / RVFA1 (lab-only, production-disabled)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from raven_protocol import full_braid_protected_anchor as pa

REPO = Path(__file__).resolve().parents[3]
VEC = REPO / "shared-vectors/rvn1/atsam/full_braid_protected_anchor_001.json"


def _load():
    return json.loads(VEC.read_text())


def test_scope_kdf_rvfa1_and_append_decisions():
    v = _load()
    assert v["production_enabled"] is False
    assert v["lab_only"] is True
    seed = bytes.fromhex(v["inputs"]["seed_hex"])
    session = bytes.fromhex(v["inputs"]["session_id_hex"])
    keys = pa.derive_store_keys(seed)
    exp = v["expected"]
    neg = v["negatives"]

    assert pa.INITIAL_ANCHOR_SEQ == 1
    assert pa.apple_scope_id().hex() == exp["apple_scope_id_hex"]
    assert (
        pa.terminal_scope_id(v["inputs"]["terminal_root_utf8"].encode()).hex()
        == exp["terminal_scope_id_hex"]
    )
    assert keys.k_state.hex() == exp["k_state_hex"]
    assert keys.k_index.hex() == exp["k_index_hex"]
    assert keys.k_sql.hex() == exp["k_sql_hex"]
    assert keys.k_local.hex() == exp["k_local_hex"]
    assert keys.k_anchor.hex() == exp["k_anchor_hex"]
    assert keys.k_sql_salt.hex() == exp["k_sql_salt_hex"]

    rk = pa.record_key(keys.k_index, session)
    assert rk.hex() == exp["record_key_hex"]

    raw1 = bytes.fromhex(exp["rvfa1_seq1_hex"])
    raw2 = bytes.fromhex(exp["rvfa1_seq2_hex"])
    raw3 = bytes.fromhex(exp["rvfa1_seq3_hex"])
    raw4 = bytes.fromhex(exp["rvfa1_seq4_hex"])
    conflict = bytes.fromhex(exp["rvfa1_seq2_conflict_hex"])
    deleting = bytes.fromhex(exp["rvfa1_deleting_seq2_hex"])
    assert len(raw1) == pa.RVFA1_LEN
    decoded = pa.decode_rvfa1(raw1, keys.k_anchor)
    assert decoded.anchor_seq == 1
    assert decoded.record_key == rk
    assert decoded.transition_id == bytes(32)

    assert (
        pa.classify_append([], raw1, keys.k_anchor, keys.k_index).value
        == exp["append_empty_seq1"]
    )
    assert (
        pa.classify_append([raw1], raw1, keys.k_anchor, keys.k_index).value
        == exp["append_replay_seq1"]
    )
    assert (
        pa.classify_append([raw1], raw2, keys.k_anchor, keys.k_index).value
        == exp["append_seq2_after_seq1"]
    )
    assert (
        pa.classify_append([raw1, raw2], conflict, keys.k_anchor, keys.k_index).value
        == exp["append_conflict_same_seq"]
    )
    assert (
        pa.classify_append([], raw2, keys.k_anchor, keys.k_index).value
        == exp["append_first_nonzero_not_one"]
    )

    gap = pa.encode_rvfa1(
        pa.Rvfa1(
            status=pa.Rvfa1Status.HEAD,
            role=0,
            record_key=rk,
            session_id=session,
            anchor_seq=4,
            generation=4,
            cleared_state_digest=bytes.fromhex("66" * 32),
            cleared_store_revision=9,
            transition_id=bytes.fromhex("77" * 32),
            horizon_ms=0,
        ),
        keys.k_anchor,
    )
    assert (
        pa.classify_append([raw1, raw2], gap, keys.k_anchor, keys.k_index).value
        == exp["append_gap_seq4"]
    )
    assert (
        pa.classify_append([raw1, raw3], raw4, keys.k_anchor, keys.k_index).value
        == exp["append_gapped_chain_seq4"]
    )
    assert (
        pa.classify_append([raw1, raw3], raw3, keys.k_anchor, keys.k_index).value
        == exp["append_replay_on_gapped_chain"]
    )
    assert (
        pa.classify_append(
            [raw1, bytes.fromhex(neg["tombstone_after_head_hex"])],
            raw1,
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_bad_status_in_chain"]
    )
    assert (
        pa.classify_append(
            [],
            bytes.fromhex(neg["bad_record_key_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_bad_record_key"]
    )
    assert (
        pa.classify_append(
            [],
            bytes.fromhex(neg["head_nonzero_horizon_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_head_nonzero_horizon"]
    )
    assert (
        pa.classify_append(
            [raw1],
            bytes.fromhex(neg["tombstone_after_head_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_bad_status_transition"]
    )
    assert (
        pa.classify_append(
            [raw1],
            bytes.fromhex(neg["tombstone_zero_horizon_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_tombstone_zero_horizon"]
    )
    assert (
        pa.classify_append(
            [raw1],
            bytes.fromhex(neg["tombstone_nonzero_transition_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_tombstone_nonzero_transition"]
    )
    assert (
        pa.classify_append(
            [raw1],
            bytes.fromhex(neg["noninitial_head_zero_transition_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_noninitial_head_zero_transition"]
    )
    assert (
        pa.classify_append(
            [raw1],
            bytes.fromhex(neg["deleting_zero_transition_hex"]),
            keys.k_anchor,
            keys.k_index,
        ).value
        == exp["append_deleting_zero_transition"]
    )
    assert (
        pa.classify_append([raw1], deleting, keys.k_anchor, keys.k_index).value
        == exp["append_deleting_after_seq1"]
    )

    assert (
        pa.open_rollback_class(2, bytes.fromhex("44" * 32), 8, 2, bytes.fromhex("44" * 32), 8)
        == exp["open_aligned"]
    )
    assert (
        pa.open_rollback_class(2, bytes.fromhex("44" * 32), 8, 1, bytes.fromhex("33" * 32), 7)
        == exp["open_container_behind"]
    )
    assert (
        pa.open_rollback_class(1, bytes.fromhex("33" * 32), 7, 2, bytes.fromhex("44" * 32), 8)
        == exp["open_anchor_behind"]
    )
    assert (
        pa.open_rollback_class(2, bytes.fromhex("44" * 32), 8, 2, bytes.fromhex("33" * 32), 8)
        == exp["open_digest_mismatch"]
    )
    assert pa.RELEASE_HOLD == "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
    assert pa.MAX_FULL_BRAID_SESSIONS == 4096
    assert pa.WINDOWS_CRED_MAX_BLOB == 2560
    assert len(pa.ERROR_CODES) == 11


def test_negatives_forbidden_group_bad_hmac_and_encode_parity():
    v = _load()
    with pytest.raises(pa.CodecError):
        pa.scope_id(pa.APPLE_APP_ID, v["negatives"]["forbidden_shared_group"].encode())
    keys = pa.derive_store_keys(bytes.fromhex(v["inputs"]["seed_hex"]))
    with pytest.raises(pa.CodecError):
        pa.decode_rvfa1(bytes.fromhex(v["negatives"]["bad_hmac_hex"]), keys.k_anchor)

    session = bytes.fromhex(v["inputs"]["session_id_hex"])
    rk = pa.record_key(keys.k_index, session)
    with pytest.raises(pa.CodecError):
        pa.encode_rvfa1(
            pa.Rvfa1(
                status=pa.Rvfa1Status.HEAD,
                role=0,
                record_key=rk,
                session_id=session,
                anchor_seq=1,
                generation=1,
                cleared_state_digest=bytes.fromhex("33" * 32),
                cleared_store_revision=7,
                transition_id=bytes(32),
                horizon_ms=0,
                hmac=bytes.fromhex("ff" * 32),
            ),
            keys.k_anchor,
        )
    assert v["negatives"]["encode_provided_hmac_mismatch"] == "CodecError"
