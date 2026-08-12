#!/usr/bin/env python3
# protocol/reference/generate_rvn1.py
"""Deterministic generator for the frozen rvn1 cross-platform vector tree.
Source of truth: raven_protocol.*  ·  Fixed keys: shared-vectors identities  ·  Epoch 1700000000."""
import argparse, json, hashlib, hmac, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from raven_protocol import address, fingerprint, routing_tag, envelope, ack, alias, device_cert, capabilities
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

EPOCH_S = 1700000000
EPOCH_MS = EPOCH_S * 1000
ALICE_ED_PRIV = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
ALICE_ED_PUB  = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
BOB_ED_PRIV   = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
BOB_ED_PUB    = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
BOB_X_PUB     = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
# dave: SHA-256(edPub)[:9] base64 contains '/', so its device fingerprint hits the
# strip-shortens-to-11-chars branch — the ~31% path no clean-key vector exercises.
DAVE_ED_PUB   = bytes.fromhex("e61a185bcef2613a6c7cb79763ce945d3b245d76114dd440bcf5f2dc1aa57057")
K_ROUTE       = bytes(range(32))

def hkdf_sha256(ikm, salt, info, length=32):
    """RFC 5869 HKDF-SHA256 (salt None → HashLen zeros). Matches CryptoKit / Rust hkdf."""
    if salt is None:
        salt = b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    t = b""
    okm = b""
    counter = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        okm += t
        counter += 1
    return okm[:length]

def write(out, rel, obj):
    p = pathlib.Path(out) / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def vec(name, desc, inputs, expected, **extra):
    return {"name": name, "description": desc, "protocol_version": "rvn1",
            "deterministic": True, "inputs": inputs, "expected": expected, **extra}

def build_message_envelope():
    rt = routing_tag.derive(K_ROUTE, EPOCH_S, 0)
    e = envelope.Envelope(
        env_type=1, flags=0, message_id=(1).to_bytes(16, "big"), routing_tag=rt,
        dest_device_hint=0, created_at=EPOCH_MS, expires_at=EPOCH_MS + 86400000,
        hop_limit=8, replication_budget=3, anti_replay_nonce=(1).to_bytes(12, "big"),
        ratchet_header_ciphertext=b"RVNA1-header-fixture",
        message_ciphertext=b"RVNS1-sealed-body-fixture", sender_authentication=b"")
    priv = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV)
    e.sender_authentication = priv.sign(envelope.signing_bytes(e))
    return e

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default=str(
        pathlib.Path(__file__).resolve().parents[2] / "shared-vectors/rvn1"))
    out = ap.parse_args().out

    write(out, "identities.json", {
        "protocol_version": "rvn1", "epoch_seconds": EPOCH_S,
        "note": "Same RFC-8032 keys as shared-vectors/v1/identities.json.",
        "alice_address": address.encode(ALICE_ED_PUB), "bob_address": address.encode(BOB_ED_PUB)})

    write(out, "address/encode_alice.json", vec(
        "RavenAddressV1 encode — alice", "bech32m over version||SHA256(edPub)[:20]",
        {"ed_public_hex": ALICE_ED_PUB.hex()},
        {"address": address.encode(ALICE_ED_PUB),
         "display": address.to_display(address.encode(ALICE_ED_PUB))}))

    write(out, "identities/fingerprint_alice.json", vec(
        "Fingerprints — alice (clean base64 branch)", "canonical device fp (app scheme) + deprecated MeshV1 hex",
        {"ed_public_hex": ALICE_ED_PUB.hex()},
        {"device_fingerprint_v1": fingerprint.device_fingerprint_v1(ALICE_ED_PUB),
         "mesh_v1_hex_deprecated": fingerprint.mesh_v1_hex_fingerprint(ALICE_ED_PUB)}))
    write(out, "identities/fingerprint_dave.json", vec(
        "Fingerprints — dave (strip branch)",
        "SHA256(edPub)[:9] base64 contains '/'; stripping shortens to 11 chars → last group is 3. "
        "Pins the ~31% branch: standard base64, strip '+'/'/' only, group the remaining chars.",
        {"ed_public_hex": DAVE_ED_PUB.hex()},
        {"device_fingerprint_v1": fingerprint.device_fingerprint_v1(DAVE_ED_PUB),
         "mesh_v1_hex_deprecated": fingerprint.mesh_v1_hex_fingerprint(DAVE_ED_PUB)}))

    write(out, "routing/tag_alice_bob_000.json", vec(
        "RavenRoutingTagV1 — counter 0", "HMAC-SHA256(K_route, label||epoch||counter)[:16]",
        {"k_route_hex": K_ROUTE.hex(), "epoch": EPOCH_S, "counter": 0},
        {"tag_hex": routing_tag.derive(K_ROUTE, EPOCH_S, 0).hex()}))
    write(out, "routing/tag_unlinkable_001.json", vec(
        "RavenRoutingTagV1 — counter 1 differs", "unlinkability across counters",
        {"k_route_hex": K_ROUTE.hex(), "epoch": EPOCH_S, "counter": 1},
        {"tag_hex": routing_tag.derive(K_ROUTE, EPOCH_S, 1).hex()}))

    e = build_message_envelope()
    write(out, "envelope/message_alice_to_bob.json", vec(
        "RavenEnvelopeV1 — message", "packed bytes, signing bytes, Ed25519 signature (alice)",
        {"signer_ed_public_hex": ALICE_ED_PUB.hex(),
         "message_id_hex": e.message_id.hex(), "routing_tag_hex": e.routing_tag.hex(),
         "created_at_ms": e.created_at, "expires_at_ms": e.expires_at,
         "ratchet_header_ciphertext_hex": e.ratchet_header_ciphertext.hex(),
         "message_ciphertext_hex": e.message_ciphertext.hex()},
        {"packed_hex": envelope.pack(e).hex(),
         "signing_bytes_hex": envelope.signing_bytes(e).hex(),
         "sender_authentication_hex": e.sender_authentication.hex()}))

    a = ack.Ack(acked_message_id=e.message_id, status=1, ack_nonce=(2).to_bytes(12, "big"),
                created_at=EPOCH_MS + 1000)
    asig = Ed25519PrivateKey.from_private_bytes(BOB_ED_PRIV).sign(ack.signing_bytes(a))
    write(out, "ack/delivered_bob_to_alice.json", vec(
        "RavenAckV1 — delivered", "ack signing bytes + Ed25519 signature (bob)",
        {"acked_message_id_hex": a.acked_message_id.hex(), "status": a.status,
         "ack_nonce_hex": a.ack_nonce.hex(), "created_at_ms": a.created_at,
         "signer_ed_public_hex": BOB_ED_PUB.hex()},
        {"signing_bytes_hex": ack.signing_bytes(a).hex(), "signature_hex": asig.hex()}))

    r = alias.AliasRecord(alias="ahmad", identity_address=address.encode(ALICE_ED_PUB),
                          sequence=42, expires_at=EPOCH_MS + 604800000)
    r.signature = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(alias.signing_bytes(r))
    write(out, "alias/ahmad_seq42.json", vec(
        "RavenAliasRecordV1 — @ahmad seq 42", "identity-signed alias record",
        {"alias": r.alias, "identity_address": r.identity_address, "sequence": r.sequence,
         "expires_at_ms": r.expires_at, "identity_ed_public_hex": ALICE_ED_PUB.hex()},
        {"signing_bytes_hex": alias.signing_bytes(r).hex(), "signature_hex": r.signature.hex()}))

    c = device_cert.DeviceCert(device_ed_pub=BOB_ED_PUB, device_x_pub=BOB_X_PUB,
                               device_id="bob-device-1", not_before=EPOCH_MS,
                               not_after=EPOCH_MS + 31536000000, capabilities=0b111)
    c.signature = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(device_cert.signing_bytes(c))
    write(out, "device_cert/bob_device1.json", vec(
        "RavenDeviceCertificateV1 — bob device authorized by alice-identity",
        "user-identity-signed device certificate",
        {"device_ed_public_hex": BOB_ED_PUB.hex(), "device_x_public_hex": BOB_X_PUB.hex(),
         "device_id": c.device_id, "not_before_ms": c.not_before, "not_after_ms": c.not_after,
         "capabilities": c.capabilities, "user_identity_ed_public_hex": ALICE_ED_PUB.hex()},
        {"signing_bytes_hex": device_cert.signing_bytes(c).hex(), "signature_hex": c.signature.hex()}))

    # RavenProtocolCapabilitiesV1 — signed capability set (downgrade protection).
    cap = capabilities.Capabilities(identity_address=address.encode(ALICE_ED_PUB),
                                    capability_bits=0b1111, expires_at=EPOCH_MS + 604800000)
    cap.signature = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(capabilities.signing_bytes(cap))
    write(out, "capabilities/alice_v1.json", vec(
        "RavenProtocolCapabilitiesV1 — alice", "identity-signed capability set for downgrade protection",
        {"identity_address": cap.identity_address, "capability_bits": cap.capability_bits,
         "expires_at_ms": cap.expires_at, "identity_ed_public_hex": ALICE_ED_PUB.hex()},
        {"signing_bytes_hex": capabilities.signing_bytes(cap).hex(), "signature_hex": cap.signature.hex()}))

    # ---- negative vectors ----
    bad_addr = address.encode(ALICE_ED_PUB)
    bad_addr = bad_addr[:-1] + ("q" if bad_addr[-1] != "q" else "p")
    write(out, "negative/address_bad_checksum.json", vec(
        "Address with corrupted checksum must fail to decode", "single-char corruption",
        {"address": bad_addr}, {"decode_result": "reject"}))

    raw = bytearray(envelope.pack(e)); raw[0] = 0
    write(out, "negative/envelope_bad_magic.json", vec(
        "Envelope with wrong magic must be rejected", "magic byte zeroed",
        {"packed_hex": bytes(raw).hex()}, {"unpack_result": "reject"}))

    tam = build_message_envelope(); tam.message_ciphertext = b"RVNS1-sealed-body-TAMPERED"
    write(out, "negative/envelope_tampered_body.json", vec(
        "Envelope body tampered after signing must fail verify", "ciphertext changed post-sign",
        {"packed_hex": envelope.pack(tam).hex(), "signer_ed_public_hex": ALICE_ED_PUB.hex()},
        {"verify_result": "reject"}))

    write(out, "negative/envelope_expired.json", vec(
        "Envelope past expires_at must be dropped by relays", "expires_at < validation clock",
        {"expires_at_ms": EPOCH_MS - 1000, "validation_clock_ms": EPOCH_MS},
        {"relay_action": "drop"}))

    r2 = alias.AliasRecord(alias="ahmad", identity_address=address.encode(ALICE_ED_PUB),
                           sequence=41, expires_at=EPOCH_MS + 604800000)
    r2.signature = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(alias.signing_bytes(r2))
    write(out, "negative/alias_stale_sequence.json", vec(
        "Older-sequence alias record must not replace a newer one", "seq 41 vs cached 42",
        {"cached_sequence": 42, "incoming_sequence": 41,
         "incoming_signing_bytes_hex": alias.signing_bytes(r2).hex()},
        {"resolver_action": "reject_stale"}))

    awrong = Ed25519PrivateKey.from_private_bytes(ALICE_ED_PRIV).sign(ack.signing_bytes(a))
    write(out, "negative/ack_wrong_signer.json", vec(
        "ACK verified against wrong key must fail", "signed by alice, verified as bob",
        {"signing_bytes_hex": ack.signing_bytes(a).hex(), "signature_hex": awrong.hex(),
         "claimed_signer_ed_public_hex": BOB_ED_PUB.hex()},
        {"verify_result": "reject"}))

    # Device cert signed by a non-identity key must not authorize the device.
    dc_wrong = Ed25519PrivateKey.from_private_bytes(BOB_ED_PRIV).sign(device_cert.signing_bytes(c))
    write(out, "negative/device_cert_wrong_signer.json", vec(
        "Device certificate not signed by the claimed user identity must fail",
        "signed by bob, verified against alice-identity",
        {"signing_bytes_hex": device_cert.signing_bytes(c).hex(), "signature_hex": dc_wrong.hex(),
         "claimed_user_identity_ed_public_hex": ALICE_ED_PUB.hex()},
        {"verify_result": "reject"}))

    # Capability set with a flipped bit after signing must fail verification (downgrade defense).
    cap_tam = capabilities.Capabilities(identity_address=cap.identity_address,
                                        capability_bits=0b0001, expires_at=cap.expires_at)
    write(out, "negative/capabilities_tampered_bits.json", vec(
        "Capability bits changed after signing must fail verify", "advertised bits downgraded post-sign",
        {"signing_bytes_hex": capabilities.signing_bytes(cap_tam).hex(),
         "original_signature_hex": cap.signature.hex(),
         "identity_ed_public_hex": ALICE_ED_PUB.hex()},
        {"verify_result": "reject"}))

    # --- Portable ATSAM / interim KATs (no ML-KEM; label agreement only) ---
    local_pub = bytes([0x01] * 32)
    peer_pub = bytes([0x02] * 32)
    a, b = (local_pub, peer_pub) if local_pub <= peer_pub else (peer_pub, local_pub)
    interim_ikm = hashlib.sha256(b"raven/rvn1/interim-psk" + a + b"|" + b).digest()
    interim_key = hkdf_sha256(interim_ikm, None, b"raven/rvn1/interim-seal/v0")
    write(out, "seal/interim_pairwise_001.json", {
        "id": "rvn1_interim_pairwise_001",
        "description": "Interim seal pairwise demo key (proto 0x7F). Not shipping ATSAM.",
        "local_pub_hex": local_pub.hex(),
        "peer_pub_hex": peer_pub.hex(),
        "pairwise_key_hex": interim_key.hex(),
        "notes": "SHA-256(raven/rvn1/interim-psk || sort(pubA,pubB) with '|') then HKDF-Expand info raven/rvn1/interim-seal/v0",
    })

    root = bytes([0x11] * 32)
    s, r = b"alice", b"bob"
    ck0 = hkdf_sha256(root, None, b"ATSAM/v2/chain-init\x00" + s + b"\x00" + r)
    ck1 = hkdf_sha256(ck0, None, b"ATSAM/v2/chain-advance")
    kmsg = hkdf_sha256(ck0, b"ATSAM/v2/msg-seal/salt", b"ATSAM/v2/msg-key\x00" + s + b"\x00" + r)
    write(out, "atsam/chain_kdf_001.json", {
        "id": "rvn1_atsam_chain_kdf_001",
        "description": "ATSAM v2 chain HKDF labels without ML-KEM — portable KAT for Rust/Swift agreement",
        "root_hex": root.hex(),
        "sender": "alice",
        "recipient": "bob",
        "ck0_hex": ck0.hex(),
        "ck1_hex": ck1.hex(),
        "k_msg_hex": kmsg.hex(),
        "labels": {
            "chain_init": "ATSAM/v2/chain-init",
            "chain_advance": "ATSAM/v2/chain-advance",
            "msg_key": "ATSAM/v2/msg-key",
            "msg_seal_salt": "ATSAM/v2/msg-seal/salt",
        },
        "gap": "ML-KEM hybrid root establishment is NOT covered — this KAT assumes a known K_root. iOS remains canonical for pairing until Rust ports ML-KEM-768.",
    })
    # Root HKDF (Z_X||Z_PQ + transcript) — matches raven-core::atsam_root / ATSAMRootDerivation
    z_x = bytes([0x11] * 32)
    z_pq = bytes([0x22] * 32)
    transcript_material = b"kat-pair-material"
    transcript_hash = hashlib.sha256(b"ATSAM/v1/transcript" + transcript_material).digest()
    k_root = hkdf_sha256(z_x + z_pq, transcript_hash, b"ATSAM/v1/pair-init" + transcript_hash)
    write(out, "atsam/root_hkdf_001.json", {
        "id": "atsam_root_hkdf_001",
        "description": "ATSAM K_root HKDF with known Z_X||Z_PQ and transcript (no ML-KEM). Matches raven-core::atsam_root and iOS ATSAMRootDerivation labels.",
        "input": {
            "z_x_hex": z_x.hex(),
            "z_pq_hex": z_pq.hex(),
            "transcript_material_utf8": transcript_material.decode(),
            "transcript_domain_utf8": "ATSAM/v1/transcript",
            "pair_init_utf8": "ATSAM/v1/pair-init",
        },
        "expected": {
            "transcript_hash_hex": transcript_hash.hex(),
            "k_root_hex": k_root.hex(),
        },
    })
    # AAD + AEAD with known K_root (no ML-KEM) — matches ATSAMMessageSealer v2
    msg_id = b"msg-001"
    index = 0
    nonce = bytes([0xAB] * 12)
    plaintext = b"portable-atsam-v2"
    aad_v2 = hashlib.sha256(
        b"ATSAM/v1/msg-seal/aad\x00"
        + bytes([0x02, 0x01])
        + index.to_bytes(4, "big")
        + b"\x00" + s + b"\x00" + r + b"\x00" + msg_id
    ).digest()
    aad_v1 = hashlib.sha256(
        b"ATSAM/v1/msg-seal/aad\x00\x00" + s + b"\x00" + r + b"\x00" + msg_id
    ).digest()
    ct_tag = ChaCha20Poly1305(kmsg).encrypt(nonce, plaintext, aad_v2)
    wire = b"RVNA1\x00\x00\x00" + bytes([0x02, 0x01]) + index.to_bytes(4, "big") + nonce + ct_tag
    write(out, "atsam/rvna1_v2_aead_known_root_001.json", {
        "id": "rvn1_atsam_rvna1_v2_aead_known_root_001",
        "description": "RVNA1 v2 ChaCha20-Poly1305 + AAD given known K_root (no ML-KEM pairing)",
        "root_hex": root.hex(),
        "sender": "alice",
        "recipient": "bob",
        "msg_id": msg_id.decode(),
        "index": index,
        "nonce_hex": nonce.hex(),
        "plaintext_hex": plaintext.hex(),
        "k_msg_hex": kmsg.hex(),
        "aad_v2_hex": aad_v2.hex(),
        "aad_v1_hex": aad_v1.hex(),
        "wire_hex": wire.hex(),
        "gap": "Does not cover ML-KEM hybrid pairing or skipped-key cache; only AEAD+AAD+chain index 0.",
    })
    write(out, "atsam/rvna1_header_layouts_001.json", {
        "id": "rvn1_rvna1_header_layouts_001",
        "description": "RVNA1 header layouts for classification (no AEAD)",
        "cases": [
            {
                "name": "interim_0x7f",
                "wire_prefix_hex": "52564e41310000007f01",
                "min_len": 38,
                "class": "interim_stub",
                "index": None,
            },
            {
                "name": "atsam_v1",
                "wire_prefix_hex": "52564e41310000000101",
                "min_len": 38,
                "class": "opaque_atsam",
                "proto": 1,
                "index": None,
            },
            {
                "name": "atsam_v2_index7",
                "wire_prefix_hex": "52564e4131000000020100000007",
                "min_len": 42,
                "class": "opaque_atsam",
                "proto": 2,
                "index": 7,
            },
        ],
    })

if __name__ == "__main__":
    main()
