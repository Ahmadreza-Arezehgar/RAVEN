//! ATSAM/hybrid-ratchet/v2 KDF + expand KATs (vector freeze).
//! Production disabled. PairInit V1 MUST NOT be reinterpreted as V2.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

pub const PROFILE: &[u8] = b"ATSAM/hybrid-ratchet/v2";
pub const TR_PROTOCOL_INFO: &[u8] = b"ATSAM/hybrid-ratchet/v2\x00TR";
pub const SPQR_PROTOCOL_INFO: &[u8] = b"ATSAM/hybrid-ratchet/v2\x00SPQR";
pub const EC_RK_INFO: &[u8] = b"ATSAM/hybrid-ratchet/v2\x00EC-KDF-RK";
pub const SCKA_INIT_INFO: &[u8] = b"ATSAM/hybrid-ratchet/v2\x00SPQR\x00SCKA-INIT";
pub const PAIR_INIT_LABEL: &[u8] = b"ATSAM/v2/pair-init";
pub const TRANSCRIPT_DOMAIN: &[u8] = b"ATSAM/v2/transcript";
pub const PAIR_EXPAND_INFO_PREFIX: &[u8] = b"ATSAM/hybrid-ratchet/v2\x00pair-expand";
pub const SESSION_ID_DOMAIN: &[u8] = b"ATSAM/v2/pair-session";
pub const INIT_MAGIC_V2: &[u8; 8] = b"RVPI2\0\0\0";
pub const INIT_MAGIC_V1: &[u8; 8] = b"RVPI1\0\0\0";
pub const SEALED_PROTO: u8 = 0x04;
pub const MAX_SKIP: u32 = 1000;

pub fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], length: usize) -> Vec<u8> {
    let salt = if salt.is_empty() {
        &[0u8; 32][..]
    } else {
        salt
    };
    let mut mac = HmacSha256::new_from_slice(salt).expect("hmac");
    mac.update(ikm);
    let prk = mac.finalize().into_bytes();
    let mut okm = Vec::new();
    let mut t = Vec::<u8>::new();
    let mut counter = 1u8;
    while okm.len() < length {
        let mut m = HmacSha256::new_from_slice(&prk).expect("hmac");
        m.update(&t);
        m.update(info);
        m.update(&[counter]);
        t = m.finalize().into_bytes().to_vec();
        okm.extend_from_slice(&t);
        counter = counter.wrapping_add(1);
    }
    okm.truncate(length);
    okm
}

pub fn reject_if_pair_init_v1(wire: &[u8]) -> Result<(), String> {
    if wire.len() >= 8 && &wire[..8] == INIT_MAGIC_V1 {
        return Err("PairInit V1 must not be reinterpreted as V2".into());
    }
    Ok(())
}

pub fn transcript_hash(wire: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(TRANSCRIPT_DOMAIN);
    h.update(PAIR_INIT_LABEL);
    h.update(wire);
    h.finalize().into()
}

pub fn init_hash_v2(wire: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(PAIR_INIT_LABEL);
    h.update(wire);
    h.finalize().into()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairExpandV2 {
    pub sk_ec: [u8; 32],
    pub sk_scka: [u8; 32],
    pub k_route_master: [u8; 32],
    pub k_confirm: [u8; 32],
    pub transcript_hash: [u8; 32],
    pub init_hash_v2: [u8; 32],
    pub session_id: [u8; 32],
}

pub fn pair_expand(z_x: &[u8; 32], z_pq: &[u8; 32], wire: &[u8]) -> Result<PairExpandV2, String> {
    reject_if_pair_init_v1(wire)?;
    if wire.len() < 8 || &wire[..8] != INIT_MAGIC_V2 {
        return Err("bad PairInit V2 magic".into());
    }
    let th = transcript_hash(wire);
    let ih = init_hash_v2(wire);
    let mut info = PAIR_EXPAND_INFO_PREFIX.to_vec();
    info.extend_from_slice(&th);
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(z_x);
    ikm[32..].copy_from_slice(z_pq);
    let okm = hkdf_sha256(&ikm, &th, &info, 128);
    let mut sk_ec = [0u8; 32];
    let mut sk_scka = [0u8; 32];
    let mut k_route = [0u8; 32];
    let mut k_confirm = [0u8; 32];
    sk_ec.copy_from_slice(&okm[0..32]);
    sk_scka.copy_from_slice(&okm[32..64]);
    k_route.copy_from_slice(&okm[64..96]);
    k_confirm.copy_from_slice(&okm[96..128]);
    let mut sid_h = Sha256::new();
    sid_h.update(SESSION_ID_DOMAIN);
    sid_h.update(ih);
    Ok(PairExpandV2 {
        sk_ec,
        sk_scka,
        k_route_master: k_route,
        k_confirm,
        transcript_hash: th,
        init_hash_v2: ih,
        session_id: sid_h.finalize().into(),
    })
}

pub fn kdf_rk(rk: &[u8; 32], dh_out: &[u8; 32]) -> Result<([u8; 32], [u8; 32]), String> {
    if *dh_out == [0u8; 32] {
        return Err("non-contributory DH".into());
    }
    let okm = hkdf_sha256(dh_out, rk, EC_RK_INFO, 64);
    let mut rk2 = [0u8; 32];
    let mut ck = [0u8; 32];
    rk2.copy_from_slice(&okm[..32]);
    ck.copy_from_slice(&okm[32..]);
    Ok((rk2, ck))
}

pub fn kdf_ck(ck: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let mut m1 = HmacSha256::new_from_slice(ck).expect("hmac");
    m1.update(&[0x01]);
    let mk: [u8; 32] = m1.finalize().into_bytes().into();
    let mut m2 = HmacSha256::new_from_slice(ck).expect("hmac");
    m2.update(&[0x02]);
    let ck2: [u8; 32] = m2.finalize().into_bytes().into();
    (ck2, mk)
}

pub fn kdf_hybrid(ec_mk: &[u8; 32], scka_mk: &[u8; 32]) -> ([u8; 32], [u8; 12]) {
    let okm = hkdf_sha256(ec_mk, scka_mk, TR_PROTOCOL_INFO, 44);
    let mut key = [0u8; 32];
    let mut nonce = [0u8; 12];
    key.copy_from_slice(&okm[..32]);
    nonce.copy_from_slice(&okm[32..44]);
    (key, nonce)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SckaInitOut {
    pub rk: [u8; 32],
    pub ck_send: [u8; 32],
    pub ck_recv: [u8; 32],
}

pub fn ratchet_init_alice_scka(sk: &[u8; 32]) -> SckaInitOut {
    let okm = hkdf_sha256(sk, &[0u8; 32], SCKA_INIT_INFO, 96);
    let mut out = SckaInitOut {
        rk: [0; 32],
        ck_send: [0; 32],
        ck_recv: [0; 32],
    };
    out.rk.copy_from_slice(&okm[0..32]);
    out.ck_send.copy_from_slice(&okm[32..64]);
    out.ck_recv.copy_from_slice(&okm[64..96]);
    out
}

pub fn ratchet_init_bob_scka(sk: &[u8; 32]) -> SckaInitOut {
    let okm = hkdf_sha256(sk, &[0u8; 32], SCKA_INIT_INFO, 96);
    let mut out = SckaInitOut {
        rk: [0; 32],
        ck_send: [0; 32],
        ck_recv: [0; 32],
    };
    out.rk.copy_from_slice(&okm[0..32]);
    out.ck_send.copy_from_slice(&okm[64..96]);
    out.ck_recv.copy_from_slice(&okm[32..64]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::PathBuf;

    fn root() -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.pop();
        p.pop();
        p.pop();
        p.join("shared-vectors/rvn1/atsam")
    }

    fn load(name: &str) -> Value {
        serde_json::from_str(&std::fs::read_to_string(root().join(name)).unwrap()).unwrap()
    }

    fn hex32(s: &str) -> [u8; 32] {
        let v = hex::decode(s).unwrap();
        let mut a = [0u8; 32];
        a.copy_from_slice(&v);
        a
    }

    #[test]
    fn pair_expand_001() {
        let v = load("pair_init_v2_001.json");
        let wire = hex::decode(v["expected"]["pair_init_wire_hex"].as_str().unwrap()).unwrap();
        assert_eq!(wire.len(), v["expected"]["pair_init_wire_len"].as_u64().unwrap() as usize);
        let zx = hex32(v["inputs"]["z_x_hex"].as_str().unwrap());
        let zp = hex32(v["inputs"]["z_pq_hex"].as_str().unwrap());
        let e = pair_expand(&zx, &zp, &wire).unwrap();
        assert_eq!(hex::encode(e.sk_ec), v["expected"]["sk_ec_hex"].as_str().unwrap());
        assert_eq!(hex::encode(e.sk_scka), v["expected"]["sk_scka_hex"].as_str().unwrap());
        assert_eq!(
            hex::encode(e.k_route_master),
            v["expected"]["k_route_master_hex"].as_str().unwrap()
        );
        assert_eq!(
            hex::encode(e.session_id),
            v["expected"]["session_id_hex"].as_str().unwrap()
        );
    }

    #[test]
    fn v1_rejected() {
        let v = load("negative/pair_init_v1_as_v2_001.json");
        let wire = hex::decode(v["inputs"]["wire_hex"].as_str().unwrap()).unwrap();
        assert!(reject_if_pair_init_v1(&wire).is_err());
    }

    #[test]
    fn ec_kdf_001() {
        let v = load("tr_ec_kdf_001.json");
        let rk = hex32(v["inputs"]["rk_hex"].as_str().unwrap());
        let dh = hex32(v["inputs"]["dh_out_hex"].as_str().unwrap());
        let (rk1, ck) = kdf_rk(&rk, &dh).unwrap();
        let (ck2, mk) = kdf_ck(&ck);
        assert_eq!(hex::encode(rk1), v["expected"]["rk_next_hex"].as_str().unwrap());
        assert_eq!(hex::encode(ck), v["expected"]["ck_hex"].as_str().unwrap());
        assert_eq!(hex::encode(ck2), v["expected"]["ck_next_hex"].as_str().unwrap());
        assert_eq!(hex::encode(mk), v["expected"]["mk_hex"].as_str().unwrap());
    }

    #[test]
    fn scka_init_001() {
        let v = load("tr_scka_init_001.json");
        let sk = hex32(v["inputs"]["sk_scka_hex"].as_str().unwrap());
        let a = ratchet_init_alice_scka(&sk);
        let b = ratchet_init_bob_scka(&sk);
        assert_eq!(
            hex::encode(a.ck_send),
            v["expected"]["alice"]["ck_send_hex"].as_str().unwrap()
        );
        assert_eq!(a.ck_send, b.ck_recv);
        assert_ne!(a.ck_send, b.ck_send);
    }

    #[test]
    fn hybrid_001() {
        let v = load("tr_hybrid_aead_001.json");
        let ec = hex32(v["inputs"]["ec_mk_hex"].as_str().unwrap());
        let pq = hex32(v["inputs"]["scka_mk_hex"].as_str().unwrap());
        let (key, nonce) = kdf_hybrid(&ec, &pq);
        assert_eq!(hex::encode(key), v["expected"]["aead_key_hex"].as_str().unwrap());
        assert_eq!(hex::encode(nonce), v["expected"]["nonce_hex"].as_str().unwrap());
    }

    #[test]
    fn sealed_proto_constant() {
        let v = load("tr_domain_labels_001.json");
        assert_eq!(v["expected"]["SEALED_PROTO"].as_str().unwrap(), "04");
        assert_eq!(SEALED_PROTO, 0x04);
        assert_eq!(MAX_SKIP, 1000);
    }
}
