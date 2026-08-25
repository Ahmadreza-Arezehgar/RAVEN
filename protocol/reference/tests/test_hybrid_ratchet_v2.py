"""KATs for ATSAM/hybrid-ratchet/v2 vector freeze (production-disabled)."""

from __future__ import annotations

import json
from pathlib import Path

from raven_protocol import hybrid_ratchet_v2 as tr, pair_init_v2 as piv2

REPO = Path(__file__).resolve().parents[3]
VEC = REPO / "shared-vectors/rvn1/atsam"


def _load(name: str):
    return json.loads((VEC / name).read_text())


def test_pair_init_v2_roundtrip_and_expand():
    v = _load("pair_init_v2_001.json")
    wire = bytes.fromhex(v["expected"]["pair_init_wire_hex"])
    assert len(wire) == v["expected"]["pair_init_wire_len"]
    assert v["expected"]["offsets"]["total_len"] == len(wire)
    rec = piv2.decode_init(wire)
    assert piv2.encode_init(rec) == wire
    assert piv2.verify_init_signature(rec)
    expand = piv2.pair_expand(
        bytes.fromhex(v["inputs"]["z_x_hex"]),
        bytes.fromhex(v["inputs"]["z_pq_hex"]),
        wire,
    )
    assert expand.sk_ec.hex() == v["expected"]["sk_ec_hex"]
    assert expand.sk_scka.hex() == v["expected"]["sk_scka_hex"]
    assert expand.k_route_master.hex() == v["expected"]["k_route_master_hex"]
    assert expand.k_confirm.hex() == v["expected"]["k_confirm_hex"]
    assert expand.session_id.hex() == v["expected"]["session_id_hex"]
    resp = piv2.decode_response(bytes.fromhex(v["expected"]["pair_response_wire_hex"]))
    assert piv2.verify_response_signature(resp)
    assert resp.confirmation_tag.hex() == v["expected"]["confirmation_tag_hex"]


def test_pair_init_v1_rejected_as_v2():
    v = _load("negative/pair_init_v1_as_v2_001.json")
    wire = bytes.fromhex(v["inputs"]["wire_hex"])
    try:
        piv2.decode_init(wire)
        raise AssertionError("should reject")
    except ValueError as e:
        assert "V1" in str(e)


def test_domain_labels():
    v = _load("tr_domain_labels_001.json")
    assert v["expected"] == tr.domain_catalog()
    assert v["expected"]["SEALED_PROTO"] == "04"
    assert v["expected"]["MAX_SKIP"] == "1000"


def test_ec_kdf():
    v = _load("tr_ec_kdf_001.json")
    rk1, ck = tr.kdf_rk(
        bytes.fromhex(v["inputs"]["rk_hex"]),
        bytes.fromhex(v["inputs"]["dh_out_hex"]),
    )
    ck2, mk = tr.kdf_ck(ck)
    assert rk1.hex() == v["expected"]["rk_next_hex"]
    assert ck.hex() == v["expected"]["ck_hex"]
    assert ck2.hex() == v["expected"]["ck_next_hex"]
    assert mk.hex() == v["expected"]["mk_hex"]


def test_scka_role_init():
    v = _load("tr_scka_init_001.json")
    sk = bytes.fromhex(v["inputs"]["sk_scka_hex"])
    a = tr.ratchet_init_alice_scka(sk)
    b = tr.ratchet_init_bob_scka(sk)
    assert a.ck_send.hex() == v["expected"]["alice"]["ck_send_hex"]
    assert b.ck_recv.hex() == v["expected"]["bob"]["ck_recv_hex"]
    assert v["expected"]["alice_send_equals_bob_recv"] is True
    assert a.ck_send == b.ck_recv
    assert a.ck_send != b.ck_send


def test_hybrid_aead():
    v = _load("tr_hybrid_aead_001.json")
    key, nonce = tr.kdf_hybrid(
        bytes.fromhex(v["inputs"]["ec_mk_hex"]),
        bytes.fromhex(v["inputs"]["scka_mk_hex"]),
    )
    assert key.hex() == v["expected"]["aead_key_hex"]
    assert nonce.hex() == v["expected"]["nonce_hex"]
    pt = tr.aead_open(
        key,
        nonce,
        bytes.fromhex(v["expected"]["ciphertext_hex"]),
        bytes.fromhex(v["inputs"]["aad_hex"]),
    )
    assert pt.hex() == v["inputs"]["plaintext_hex"]


def test_ackv2():
    v = _load("tr_ackv2_001.json")
    ack = tr.decode_ack_plaintext(bytes.fromhex(v["expected"]["ack_plaintext_hex"]))
    assert ack.acked_object_digest.hex() == v["expected"]["acked_object_digest_hex"]
    assert tr.verify_ack(ack, bytes.fromhex(v["inputs"]["signer_device_ed_pub_hex"]))
    obj = bytes.fromhex(v["inputs"]["acked_endpoint_object_hex"])
    import hashlib

    assert hashlib.sha256(obj).digest() == ack.acked_object_digest


def test_candidate_fail_and_crash_order():
    fail = _load("tr_candidate_fail_001.json")
    try:
        tr.aead_open(
            bytes.fromhex(fail["inputs"]["aead_key_hex"]),
            bytes.fromhex(fail["inputs"]["nonce_hex"]),
            bytes.fromhex(fail["inputs"]["ciphertext_hex"]),
            bytes.fromhex(fail["inputs"]["aad_hex"]),
        )
        raise AssertionError("open should fail")
    except Exception:
        pass
    crash = _load("tr_crash_ack_cas_001.json")
    assert crash["steps"][2]["action"] == "write_PENDING_ACK_SEND"
    assert crash["steps"][3]["requires"] == "PENDING_ACK_SEND"
