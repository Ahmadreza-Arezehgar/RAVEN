//! RavenPrekeyBundleV1 — signed hybrid first-contact material.
//!
//! Spec: `protocol/RAVEN_PREKEY_BUNDLE_V1.md`
//! Publish/fetch for serverless: local file / opaque store / DiscoveryStore —
//! **never** a FastAPI people directory.

use crate::canon::{lp, u64_be};
use crate::identity::Identity;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const PREKEY_DOMAIN: &[u8] = b"rvn1/prekey";
pub const MLKEM768_EK_LEN: usize = 1184;
const PREKEY_DHT_DOMAIN: &[u8] = b"rvn1/prekey-key";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrekeyBundle {
    pub identity_ed25519_pub: [u8; 32],
    pub device_id: String,
    pub x25519_pub: [u8; 32],
    pub mlkem768_ek: Vec<u8>,
    pub signed_prekey_id: u32,
    pub one_time_prekey_id: u32,
    pub one_time_x25519_pub: Option<[u8; 32]>,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub signature: [u8; 64],
}

/// JSON export for OOB / untrusted store (hex fields only — no private keys).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrekeyBundleJson {
    pub version: u8,
    pub identity_ed25519_pub_hex: String,
    pub device_id: String,
    pub x25519_pub_hex: String,
    pub mlkem768_ek_hex: String,
    pub signed_prekey_id: u32,
    pub one_time_prekey_id: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub one_time_x25519_pub_hex: Option<String>,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub signature_hex: String,
}

impl PrekeyBundle {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        if self.mlkem768_ek.len() != MLKEM768_EK_LEN {
            return Err("mlkem ek length".into());
        }
        if self.one_time_prekey_id == 0 && self.one_time_x25519_pub.is_some() {
            return Err("otp inconsistency".into());
        }
        if self.one_time_prekey_id != 0 && self.one_time_x25519_pub.is_none() {
            return Err("otp missing key".into());
        }
        let mut out = PREKEY_DOMAIN.to_vec();
        out.push(1);
        out.extend_from_slice(&self.identity_ed25519_pub);
        out.extend(lp(self.device_id.as_bytes())?);
        out.extend_from_slice(&self.x25519_pub);
        out.extend_from_slice(&self.mlkem768_ek);
        out.extend_from_slice(&self.signed_prekey_id.to_be_bytes());
        out.extend_from_slice(&self.one_time_prekey_id.to_be_bytes());
        if let Some(otp) = self.one_time_x25519_pub {
            out.extend_from_slice(&otp);
        }
        out.extend_from_slice(&u64_be(self.created_at_ms));
        out.extend_from_slice(&u64_be(self.expires_at_ms));
        Ok(out)
    }

    pub fn sign(mut self, id: &Identity) -> Result<Self, String> {
        self.identity_ed25519_pub = id.public_key_bytes();
        let sb = self.signing_bytes()?;
        self.signature = id.sign(&sb);
        Ok(self)
    }

    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if self.expires_at_ms <= self.created_at_ms {
            return Err("PREKEY_EXPIRED".into());
        }
        let skew = 5 * 60 * 1000u64;
        if now_ms.saturating_add(skew) < self.created_at_ms {
            return Err("PREKEY_NOT_YET_VALID".into());
        }
        if now_ms > self.expires_at_ms.saturating_add(skew) {
            return Err("PREKEY_EXPIRED".into());
        }
        if self.mlkem768_ek.iter().all(|&b| b == 0) {
            return Err("PREKEY_DEGRADED_EK".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.identity_ed25519_pub, &sb, &self.signature) {
            return Err("PREKEY_BAD_SIG".into());
        }
        Ok(())
    }

    /// Lookup key for untrusted DHT / store: SHA-256("rvn1/prekey-key" || ed_pub).
    pub fn store_key(ed_pub: &[u8; 32]) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(PREKEY_DHT_DOMAIN);
        h.update(ed_pub);
        h.finalize().into()
    }

    pub fn to_json(&self) -> PrekeyBundleJson {
        PrekeyBundleJson {
            version: 1,
            identity_ed25519_pub_hex: hex::encode(self.identity_ed25519_pub),
            device_id: self.device_id.clone(),
            x25519_pub_hex: hex::encode(self.x25519_pub),
            mlkem768_ek_hex: hex::encode(&self.mlkem768_ek),
            signed_prekey_id: self.signed_prekey_id,
            one_time_prekey_id: self.one_time_prekey_id,
            one_time_x25519_pub_hex: self.one_time_x25519_pub.map(hex::encode),
            created_at_ms: self.created_at_ms,
            expires_at_ms: self.expires_at_ms,
            signature_hex: hex::encode(self.signature),
        }
    }

    pub fn from_json(j: &PrekeyBundleJson) -> Result<Self, String> {
        if j.version != 1 {
            return Err("PREKEY_VERSION".into());
        }
        let identity_ed25519_pub = decode_arr32(&j.identity_ed25519_pub_hex)?;
        let x25519_pub = decode_arr32(&j.x25519_pub_hex)?;
        let mlkem768_ek = hex::decode(&j.mlkem768_ek_hex).map_err(|e| e.to_string())?;
        if mlkem768_ek.len() != MLKEM768_EK_LEN {
            return Err("mlkem ek length".into());
        }
        let one_time_x25519_pub = match &j.one_time_x25519_pub_hex {
            Some(h) => Some(decode_arr32(h)?),
            None => None,
        };
        let signature = decode_arr64(&j.signature_hex)?;
        Ok(Self {
            identity_ed25519_pub,
            device_id: j.device_id.clone(),
            x25519_pub,
            mlkem768_ek,
            signed_prekey_id: j.signed_prekey_id,
            one_time_prekey_id: j.one_time_prekey_id,
            one_time_x25519_pub,
            created_at_ms: j.created_at_ms,
            expires_at_ms: j.expires_at_ms,
            signature,
        })
    }

    /// Build an unsigned bundle from real hybrid public material (X25519 + ML-KEM EK).
    /// Caller must `.sign(identity)` before publish. Private seeds stay with the caller.
    pub fn from_hybrid_public(
        device_id: impl Into<String>,
        x25519_pub: [u8; 32],
        mlkem768_ek: Vec<u8>,
        signed_prekey_id: u32,
        created_at_ms: u64,
        expires_at_ms: u64,
    ) -> Result<Self, String> {
        if mlkem768_ek.len() != MLKEM768_EK_LEN {
            return Err("mlkem ek length".into());
        }
        if mlkem768_ek.iter().all(|&b| b == 0) {
            return Err("PREKEY_DEGRADED_EK".into());
        }
        Ok(Self {
            identity_ed25519_pub: [0u8; 32],
            device_id: device_id.into(),
            x25519_pub,
            mlkem768_ek,
            signed_prekey_id,
            one_time_prekey_id: 0,
            one_time_x25519_pub: None,
            created_at_ms,
            expires_at_ms,
            signature: [0u8; 64],
        })
    }
}

fn decode_arr32(s: &str) -> Result<[u8; 32], String> {
    let v = hex::decode(s).map_err(|e| e.to_string())?;
    if v.len() != 32 {
        return Err("expected 32 bytes".into());
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

fn decode_arr64(s: &str) -> Result<[u8; 64], String> {
    let v = hex::decode(s).map_err(|e| e.to_string())?;
    if v.len() != 64 {
        return Err("expected 64 bytes".into());
    }
    let mut a = [0u8; 64];
    a.copy_from_slice(&v);
    Ok(a)
}

/// Local untrusted prekey cache (file-backed DHT/store stand-in). Never FastAPI.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct PrekeyStore {
    /// hex(store_key) → latest verified bundle JSON
    bundles: HashMap<String, PrekeyBundleJson>,
}

impl PrekeyStore {
    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join("prekey_store.json")
    }

    pub fn load(data_dir: &Path) -> Self {
        let Ok(raw) = std::fs::read_to_string(Self::path(data_dir)) else {
            return Self::default();
        };
        serde_json::from_str(&raw).unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), String> {
        std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
        let raw = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        let path = Self::path(data_dir);
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&path)
                .map_err(|e| e.to_string())?;
            f.write_all(raw.as_bytes()).map_err(|e| e.to_string())?;
        }
        #[cfg(not(unix))]
        {
            std::fs::write(&path, raw).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub fn publish(&mut self, bundle: &PrekeyBundle, now_ms: u64) -> Result<(), String> {
        bundle.verify(now_ms)?;
        let key = hex::encode(PrekeyBundle::store_key(&bundle.identity_ed25519_pub));
        self.bundles.insert(key, bundle.to_json());
        Ok(())
    }

    pub fn fetch(&self, ed_pub: &[u8; 32], now_ms: u64) -> Result<Option<PrekeyBundle>, String> {
        let key = hex::encode(PrekeyBundle::store_key(ed_pub));
        let Some(j) = self.bundles.get(&key) else {
            return Ok(None);
        };
        let b = PrekeyBundle::from_json(j)?;
        b.verify(now_ms)?;
        if &b.identity_ed25519_pub != ed_pub {
            return Err("PREKEY_IDENTITY_MISMATCH".into());
        }
        Ok(Some(b))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn demo_bundle(id: &Identity) -> PrekeyBundle {
        PrekeyBundle {
            identity_ed25519_pub: id.public_key_bytes(),
            device_id: "dev1".into(),
            x25519_pub: [7u8; 32],
            mlkem768_ek: vec![3u8; MLKEM768_EK_LEN],
            signed_prekey_id: 1,
            one_time_prekey_id: 0,
            one_time_x25519_pub: None,
            created_at_ms: 1_000,
            expires_at_ms: 9_000_000_000_000,
            signature: [0u8; 64],
        }
    }

    #[test]
    fn sign_verify_ok() {
        let id = Identity::generate();
        let b = demo_bundle(&id).sign(&id).unwrap();
        b.verify(2_000).unwrap();
    }

    #[test]
    fn bad_sig_rejected() {
        let id = Identity::generate();
        let mut b = demo_bundle(&id).sign(&id).unwrap();
        b.signature[0] ^= 0xff;
        assert_eq!(b.verify(2_000).unwrap_err(), "PREKEY_BAD_SIG");
    }

    #[test]
    fn zero_ek_rejected() {
        let id = Identity::generate();
        let mut b = demo_bundle(&id);
        b.mlkem768_ek = vec![0u8; MLKEM768_EK_LEN];
        let b = b.sign(&id).unwrap();
        assert_eq!(b.verify(2_000).unwrap_err(), "PREKEY_DEGRADED_EK");
    }

    #[test]
    fn local_store_publish_fetch_no_fastapi() {
        let dir = tempdir().unwrap();
        let id = Identity::generate();
        let b = demo_bundle(&id).sign(&id).unwrap();
        let mut store = PrekeyStore::default();
        store.publish(&b, 2_000).unwrap();
        store.save(dir.path()).unwrap();
        let loaded = PrekeyStore::load(dir.path());
        let got = loaded
            .fetch(&id.public_key_bytes(), 2_000)
            .unwrap()
            .unwrap();
        assert_eq!(got.signed_prekey_id, 1);
        assert_eq!(got.device_id, "dev1");
    }

    #[test]
    fn json_roundtrip() {
        let id = Identity::generate();
        let b = demo_bundle(&id).sign(&id).unwrap();
        let j = b.to_json();
        let back = PrekeyBundle::from_json(&j).unwrap();
        back.verify(2_000).unwrap();
        assert_eq!(back.mlkem768_ek.len(), MLKEM768_EK_LEN);
    }
}
