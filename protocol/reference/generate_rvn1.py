#!/usr/bin/env python3
# protocol/reference/generate_rvn1.py
"""Deterministic generator for the frozen rvn1 cross-platform vector tree.
Source of truth: raven_protocol.*  ·  Fixed keys: shared-vectors identities  ·  Epoch 1700000000."""
import argparse, json, hashlib, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from raven_protocol import address, fingerprint, routing_tag, envelope, ack, alias, device_cert, capabilities
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

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

if __name__ == "__main__":
    main()
