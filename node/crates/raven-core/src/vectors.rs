//! Load and assert `shared-vectors/rvn1` fixtures.

use serde_json::Value;
use std::path::PathBuf;

use crate::ack::Ack;
use crate::address::{decode_address, encode_address, to_display};
use crate::envelope::Envelope;
use crate::fingerprint::{device_fingerprint_v1, mesh_v1_hex_fingerprint};
use crate::identity::Identity;
use crate::records::{
    alias_signing_bytes, capabilities_signing_bytes, device_cert_signing_bytes, verify_sig,
};
use crate::routing_tag;

fn vectors_root() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop(); // crates
    p.pop(); // node
    p.pop(); // repo
    p.join("shared-vectors").join("rvn1")
}

fn load_json(rel: &str) -> Value {
    let path = vectors_root().join(rel);
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing vector {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("json")
}

fn hex_to_vec(s: &str) -> Vec<u8> {
    hex::decode(s).expect("hex")
}

fn hex_to_arr32(s: &str) -> [u8; 32] {
    let v = hex_to_vec(s);
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    a
}

fn hex_to_arr16(s: &str) -> [u8; 16] {
    let v = hex_to_vec(s);
    let mut a = [0u8; 16];
    a.copy_from_slice(&v);
    a
}

fn hex_to_arr12(s: &str) -> [u8; 12] {
    let v = hex_to_vec(s);
    let mut a = [0u8; 12];
    a.copy_from_slice(&v);
    a
}

const ALICE_SEED: &str = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
const BOB_SEED: &str = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb";

pub fn assert_all_rvn1_vectors() {
    // Address
    {
        let v = load_json("address/encode_alice.json");
        let ed = hex_to_arr32(v["inputs"]["ed_public_hex"].as_str().unwrap());
        let addr = encode_address(&ed);
        assert_eq!(addr, v["expected"]["address"].as_str().unwrap());
        assert_eq!(to_display(&addr), v["expected"]["display"].as_str().unwrap());
    }

    // Fingerprints
    for name in [
        "identities/fingerprint_alice.json",
        "identities/fingerprint_dave.json",
    ] {
        let v = load_json(name);
        let ed = hex_to_arr32(v["inputs"]["ed_public_hex"].as_str().unwrap());
        assert_eq!(
            device_fingerprint_v1(&ed),
            v["expected"]["device_fingerprint_v1"].as_str().unwrap()
        );
        assert_eq!(
            mesh_v1_hex_fingerprint(&ed),
            v["expected"]["mesh_v1_hex_deprecated"].as_str().unwrap()
        );
    }

    // Routing tags
    for name in [
        "routing/tag_alice_bob_000.json",
        "routing/tag_unlinkable_001.json",
    ] {
        let v = load_json(name);
        let k = hex_to_vec(v["inputs"]["k_route_hex"].as_str().unwrap());
        let epoch = v["inputs"]["epoch"].as_u64().unwrap();
        let counter = v["inputs"]["counter"].as_u64().unwrap();
        let tag = routing_tag::derive(&k, epoch, counter);
        assert_eq!(hex::encode(tag), v["expected"]["tag_hex"].as_str().unwrap());
    }

    // Envelope positive
    {
        let v = load_json("envelope/message_alice_to_bob.json");
        let inp = &v["inputs"];
        // Fixture uses counter-derived nonce: (1).to_bytes(12, 'big')
        let mut anti_replay_nonce = [0u8; 12];
        anti_replay_nonce[11] = 1;
        let mut env = Envelope {
            env_type: 1,
            flags: 0,
            message_id: hex_to_arr16(inp["message_id_hex"].as_str().unwrap()),
            routing_tag: hex_to_arr16(inp["routing_tag_hex"].as_str().unwrap()),
            dest_device_hint: 0,
            created_at: inp["created_at_ms"].as_u64().unwrap(),
            expires_at: inp["expires_at_ms"].as_u64().unwrap(),
            hop_limit: 8,
            replication_budget: 3,
            anti_replay_nonce,
            ratchet_header_ciphertext: hex_to_vec(
                inp["ratchet_header_ciphertext_hex"].as_str().unwrap(),
            ),
            message_ciphertext: hex_to_vec(inp["message_ciphertext_hex"].as_str().unwrap()),
            sender_authentication: vec![],
        };
        assert_eq!(
            hex::encode(env.signing_bytes()),
            v["expected"]["signing_bytes_hex"].as_str().unwrap()
        );
        let alice = Identity::from_seed(&hex_to_arr32(ALICE_SEED));
        env.sign_with(&alice);
        assert_eq!(
            hex::encode(&env.sender_authentication),
            v["expected"]["sender_authentication_hex"].as_str().unwrap()
        );
        let packed = env.pack();
        assert_eq!(
            hex::encode(&packed),
            v["expected"]["packed_hex"].as_str().unwrap()
        );
        let unpacked = Envelope::unpack(&packed).expect("unpack");
        assert!(unpacked.verify(&alice.public_key_bytes()));
    }

    // Envelope negatives
    {
        let v = load_json("negative/envelope_bad_magic.json");
        let raw = hex_to_vec(v["inputs"]["packed_hex"].as_str().unwrap());
        assert!(Envelope::unpack(&raw).is_none());
    }
    {
        let v = load_json("negative/envelope_tampered_body.json");
        let raw = hex_to_vec(v["inputs"]["packed_hex"].as_str().unwrap());
        let env = Envelope::unpack(&raw).expect("structurally valid");
        let alice_pub = hex_to_arr32(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        );
        assert!(!env.verify(&alice_pub));
        assert_eq!(v["expected"]["verify_result"].as_str().unwrap(), "reject");
    }
    {
        let v = load_json("negative/envelope_expired.json");
        let expires = v["inputs"]["expires_at_ms"].as_u64().unwrap();
        let clock = v["inputs"]["validation_clock_ms"].as_u64().unwrap();
        assert!(expires < clock);
        assert_eq!(v["expected"]["relay_action"].as_str().unwrap(), "drop");
    }

    // Address bad checksum
    {
        let v = load_json("negative/address_bad_checksum.json");
        assert!(decode_address(v["inputs"]["address"].as_str().unwrap()).is_none());
    }

    // ACK positive
    {
        let v = load_json("ack/delivered_bob_to_alice.json");
        let inp = &v["inputs"];
        let ack = Ack {
            acked_message_id: hex_to_arr16(inp["acked_message_id_hex"].as_str().unwrap()),
            status: inp["status"].as_u64().unwrap() as u8,
            ack_nonce: hex_to_arr12(inp["ack_nonce_hex"].as_str().unwrap()),
            created_at: inp["created_at_ms"].as_u64().unwrap(),
        };
        assert_eq!(
            hex::encode(ack.signing_bytes()),
            v["expected"]["signing_bytes_hex"].as_str().unwrap()
        );
        let bob = Identity::from_seed(&hex_to_arr32(BOB_SEED));
        let sig = ack.sign(&bob);
        assert_eq!(
            hex::encode(sig),
            v["expected"]["signature_hex"].as_str().unwrap()
        );
        assert!(ack.verify(&sig, &bob.public_key_bytes()));
    }
    // ACK wrong signer — signature does not verify under claimed key
    {
        let v = load_json("negative/ack_wrong_signer.json");
        let sb = hex_to_vec(v["inputs"]["signing_bytes_hex"].as_str().unwrap());
        let sig = hex_to_vec(v["inputs"]["signature_hex"].as_str().unwrap());
        let claimed = hex_to_arr32(v["inputs"]["claimed_signer_ed_public_hex"].as_str().unwrap());
        assert!(!verify_sig(&claimed, &sb, &sig));
    }

    // Alias
    {
        let v = load_json("alias/ahmad_seq42.json");
        let inp = &v["inputs"];
        let sb = alias_signing_bytes(
            inp["alias"].as_str().unwrap(),
            inp["identity_address"].as_str().unwrap(),
            inp["sequence"].as_u64().unwrap(),
            inp["expires_at_ms"].as_u64().unwrap(),
        )
        .unwrap();
        assert_eq!(
            hex::encode(&sb),
            v["expected"]["signing_bytes_hex"].as_str().unwrap()
        );
        let alice = Identity::from_seed(&hex_to_arr32(ALICE_SEED));
        let sig = alice.sign(&sb);
        assert_eq!(
            hex::encode(sig),
            v["expected"]["signature_hex"].as_str().unwrap()
        );
    }
    {
        let v = load_json("negative/alias_stale_sequence.json");
        let cached = v["inputs"]["cached_sequence"].as_u64().unwrap();
        let incoming = v["inputs"]["incoming_sequence"].as_u64().unwrap();
        assert!(incoming < cached);
        assert_eq!(
            v["expected"]["resolver_action"].as_str().unwrap(),
            "reject_stale"
        );
    }

    // Device cert
    {
        let v = load_json("device_cert/bob_device1.json");
        let inp = &v["inputs"];
        let sb = device_cert_signing_bytes(
            &hex_to_vec(inp["device_ed_public_hex"].as_str().unwrap()),
            &hex_to_vec(inp["device_x_public_hex"].as_str().unwrap()),
            inp["device_id"].as_str().unwrap(),
            inp["not_before_ms"].as_u64().unwrap(),
            inp["not_after_ms"].as_u64().unwrap(),
            inp["capabilities"].as_u64().unwrap(),
        )
        .unwrap();
        assert_eq!(
            hex::encode(&sb),
            v["expected"]["signing_bytes_hex"].as_str().unwrap()
        );
        let signer = Identity::from_seed(&hex_to_arr32(ALICE_SEED));
        let sig = signer.sign(&sb);
        assert_eq!(
            hex::encode(sig),
            v["expected"]["signature_hex"].as_str().unwrap()
        );
    }
    {
        let v = load_json("negative/device_cert_wrong_signer.json");
        let sb = hex_to_vec(v["inputs"]["signing_bytes_hex"].as_str().unwrap());
        let sig = hex_to_vec(v["inputs"]["signature_hex"].as_str().unwrap());
        let claimed =
            hex_to_arr32(v["inputs"]["claimed_user_identity_ed_public_hex"].as_str().unwrap());
        assert!(!verify_sig(&claimed, &sb, &sig));
    }

    // Capabilities
    {
        let v = load_json("capabilities/alice_v1.json");
        let inp = &v["inputs"];
        let sb = capabilities_signing_bytes(
            inp["identity_address"].as_str().unwrap(),
            inp["capability_bits"].as_u64().unwrap(),
            inp["expires_at_ms"].as_u64().unwrap(),
        )
        .unwrap();
        assert_eq!(
            hex::encode(&sb),
            v["expected"]["signing_bytes_hex"].as_str().unwrap()
        );
        let alice = Identity::from_seed(&hex_to_arr32(ALICE_SEED));
        let sig = alice.sign(&sb);
        assert_eq!(
            hex::encode(sig),
            v["expected"]["signature_hex"].as_str().unwrap()
        );
    }
    {
        let v = load_json("negative/capabilities_tampered_bits.json");
        let sb = hex_to_vec(v["inputs"]["signing_bytes_hex"].as_str().unwrap());
        let sig = hex_to_vec(v["inputs"]["original_signature_hex"].as_str().unwrap());
        let pubk = hex_to_arr32(v["inputs"]["identity_ed_public_hex"].as_str().unwrap());
        assert!(!verify_sig(&pubk, &sb, &sig));
    }

    // Interim seal pairwise + ATSAM chain KDF (no ML-KEM)
    {
        use crate::seal::derive_pairwise_key;
        let v = load_json("seal/interim_pairwise_001.json");
        let a = hex_to_arr32(v["local_pub_hex"].as_str().unwrap());
        let b = hex_to_arr32(v["peer_pub_hex"].as_str().unwrap());
        let key = derive_pairwise_key(&a, &b);
        assert_eq!(hex::encode(key), v["pairwise_key_hex"].as_str().unwrap());
    }
    {
        use crate::atsam_kdf::{advance_chain_key, initial_chain_key, message_key};
        let v = load_json("atsam/chain_kdf_001.json");
        let root = hex_to_arr32(v["root_hex"].as_str().unwrap());
        let sender = v["sender"].as_str().unwrap();
        let recipient = v["recipient"].as_str().unwrap();
        let ck0 = initial_chain_key(&root, sender, recipient);
        assert_eq!(hex::encode(ck0), v["ck0_hex"].as_str().unwrap());
        let ck1 = advance_chain_key(&ck0);
        assert_eq!(hex::encode(ck1), v["ck1_hex"].as_str().unwrap());
        let kmsg = message_key(&ck0, sender, recipient);
        assert_eq!(hex::encode(kmsg), v["k_msg_hex"].as_str().unwrap());
    }
    {
        use crate::seal::{classify_sealed_body, parse_rvna1_header, SealClass};
        let v = load_json("atsam/rvna1_header_layouts_001.json");
        for case in v["cases"].as_array().unwrap() {
            let mut wire = hex_to_vec(case["wire_prefix_hex"].as_str().unwrap());
            let min = case["min_len"].as_u64().unwrap() as usize;
            while wire.len() < min {
                wire.push(0);
            }
            let class = case["class"].as_str().unwrap();
            match class {
                "interim_stub" => {
                    assert_eq!(classify_sealed_body(&wire), SealClass::InterimStub);
                }
                "opaque_atsam" => {
                    let proto = case["proto"].as_u64().unwrap() as u8;
                    assert_eq!(
                        classify_sealed_body(&wire),
                        SealClass::OpaqueAtsam { proto }
                    );
                }
                other => panic!("unknown class {other}"),
            }
            let hdr = parse_rvna1_header(&wire).expect("header");
            match case["index"].as_u64() {
                Some(i) => assert_eq!(hdr.index, Some(i as u32)),
                None => assert!(hdr.index.is_none()),
            }
        }
    }
    {
        use crate::atsam_aead::{build_aad_v1, build_aad_v2, seal_rvna1_v2, unseal_rvna1_v2};
        let v = load_json("atsam/rvna1_v2_aead_known_root_001.json");
        let root = hex_to_arr32(v["root_hex"].as_str().unwrap());
        let sender = v["sender"].as_str().unwrap();
        let recipient = v["recipient"].as_str().unwrap();
        let msg_id = v["msg_id"].as_str().unwrap();
        let index = v["index"].as_u64().unwrap() as u32;
        let nonce = {
            let b = hex_to_vec(v["nonce_hex"].as_str().unwrap());
            let mut n = [0u8; 12];
            n.copy_from_slice(&b);
            n
        };
        let plaintext = hex_to_vec(v["plaintext_hex"].as_str().unwrap());
        assert_eq!(
            hex::encode(build_aad_v2(0x02, 0x01, index, sender, recipient, msg_id)),
            v["aad_v2_hex"].as_str().unwrap()
        );
        assert_eq!(
            hex::encode(build_aad_v1(sender, recipient, msg_id)),
            v["aad_v1_hex"].as_str().unwrap()
        );
        let wire = seal_rvna1_v2(
            &root, sender, recipient, msg_id, index, &plaintext, &nonce,
        )
        .expect("seal");
        assert_eq!(hex::encode(&wire), v["wire_hex"].as_str().unwrap());
        let pt = unseal_rvna1_v2(&root, &wire, sender, recipient, msg_id).expect("unseal");
        assert_eq!(pt, plaintext);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::Envelope;

    #[test]
    fn all_rvn1_vectors() {
        assert_all_rvn1_vectors();
    }

    #[test]
    fn vectors_root_exists() {
        assert!(vectors_root().join("identities.json").is_file());
    }

    #[test]
    fn malformed_envelope_no_panic() {
        assert!(Envelope::unpack(&[]).is_none());
        assert!(Envelope::unpack(&[0u8; 10]).is_none());
        assert!(Envelope::unpack(&[0u8; 86]).is_none());
        let mut almost = vec![0u8; 200];
        almost[0..4].copy_from_slice(b"RVN1");
        almost[4] = 1;
        let _ = Envelope::unpack(&almost);
    }
}
