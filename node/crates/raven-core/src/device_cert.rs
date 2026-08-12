//! Multi-device certificates (§39) — user-identity-signed device auth + local revoke.
//!
//! Spec: `protocol/RAVEN_IDENTITY_V1.md`. V1 has no network push-revocation
//! channel; this module implements issuance, local store, expiry checks, and a
//! local revocation denylist (software substitute until a dedicated revocation
//! record type is frozen).

use crate::identity::Identity;
use crate::records::device_cert_signing_bytes;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

fn ser_32<S: Serializer>(v: &[u8; 32], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&hex::encode(v))
}
fn de_32<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 32], D::Error> {
    let s = String::deserialize(d)?;
    let v = hex::decode(&s).map_err(serde::de::Error::custom)?;
    if v.len() != 32 {
        return Err(serde::de::Error::custom("expected 32 bytes"));
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}
fn ser_64<S: Serializer>(v: &[u8; 64], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&hex::encode(v))
}
fn de_64<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 64], D::Error> {
    let s = String::deserialize(d)?;
    let v = hex::decode(&s).map_err(serde::de::Error::custom)?;
    if v.len() != 64 {
        return Err(serde::de::Error::custom("expected 64 bytes"));
    }
    let mut a = [0u8; 64];
    a.copy_from_slice(&v);
    Ok(a)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceCertificate {
    #[serde(serialize_with = "ser_32", deserialize_with = "de_32")]
    pub device_ed_pub: [u8; 32],
    #[serde(serialize_with = "ser_32", deserialize_with = "de_32")]
    pub device_x_pub: [u8; 32],
    pub device_id: String,
    pub not_before_ms: u64,
    pub not_after_ms: u64,
    pub capabilities: u64,
    #[serde(serialize_with = "ser_64", deserialize_with = "de_64")]
    pub signature: [u8; 64],
    /// Signer (user identity) public key — recovered at verify time by caller.
    #[serde(serialize_with = "ser_32", deserialize_with = "de_32")]
    pub user_ed_pub: [u8; 32],
}

impl DeviceCertificate {
    pub fn issue(
        user: &Identity,
        device_ed_pub: [u8; 32],
        device_x_pub: [u8; 32],
        device_id: impl Into<String>,
        not_before_ms: u64,
        not_after_ms: u64,
        capabilities: u64,
    ) -> Result<Self, String> {
        let device_id = device_id.into();
        if not_after_ms < not_before_ms {
            return Err("not_after before not_before".into());
        }
        let sb = device_cert_signing_bytes(
            &device_ed_pub,
            &device_x_pub,
            &device_id,
            not_before_ms,
            not_after_ms,
            capabilities,
        )?;
        let signature = user.sign(&sb);
        Ok(Self {
            device_ed_pub,
            device_x_pub,
            device_id,
            not_before_ms,
            not_after_ms,
            capabilities,
            signature,
            user_ed_pub: user.public_key_bytes(),
        })
    }

    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if now_ms < self.not_before_ms {
            return Err("DEVICE_CERT_NOT_YET_VALID".into());
        }
        if now_ms > self.not_after_ms {
            return Err("DEVICE_CERT_EXPIRED".into());
        }
        let sb = device_cert_signing_bytes(
            &self.device_ed_pub,
            &self.device_x_pub,
            &self.device_id,
            self.not_before_ms,
            self.not_after_ms,
            self.capabilities,
        )?;
        if !Identity::verify(&self.user_ed_pub, &sb, &self.signature) {
            return Err("DEVICE_CERT_BAD_SIG".into());
        }
        Ok(())
    }
}

/// Local multi-device registry for one user identity.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct DeviceRegistry {
    /// device_id → certificate
    pub certs: HashMap<String, DeviceCertificate>,
    /// Locally revoked device_ids (no network push in V1).
    pub revoked: HashSet<String>,
}

impl DeviceRegistry {
    pub fn add(&mut self, cert: DeviceCertificate, now_ms: u64) -> Result<(), String> {
        cert.verify(now_ms)?;
        if self.revoked.contains(&cert.device_id) {
            return Err("DEVICE_REVOKED".into());
        }
        self.certs.insert(cert.device_id.clone(), cert);
        Ok(())
    }

    pub fn revoke(&mut self, device_id: &str) -> bool {
        self.revoked.insert(device_id.to_string());
        self.certs.remove(device_id);
        true
    }

    pub fn is_authorized(&self, device_id: &str, now_ms: u64) -> bool {
        if self.revoked.contains(device_id) {
            return false;
        }
        match self.certs.get(device_id) {
            Some(c) => c.verify(now_ms).is_ok(),
            None => false,
        }
    }

    pub fn lookup_by_ed_pub(&self, ed: &[u8; 32], now_ms: u64) -> Option<&DeviceCertificate> {
        self.certs.values().find(|c| {
            &c.device_ed_pub == ed && !self.revoked.contains(&c.device_id) && c.verify(now_ms).is_ok()
        })
    }
}

pub fn device_registry_path(data_dir: &Path) -> PathBuf {
    data_dir.join("device_registry.json")
}

pub fn load_device_registry(data_dir: &Path) -> DeviceRegistry {
    let path = device_registry_path(data_dir);
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return DeviceRegistry::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_device_registry(data_dir: &Path, reg: &DeviceRegistry) -> Result<(), String> {
    std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
    let path = device_registry_path(data_dir);
    let raw = serde_json::to_string_pretty(reg).map_err(|e| e.to_string())?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn add_and_revoke_device() {
        let user = Identity::generate();
        let device = Identity::generate();
        let x = [9u8; 32];
        let cert = DeviceCertificate::issue(
            &user,
            device.public_key_bytes(),
            x,
            "phone-1",
            1,
            u64::MAX / 2,
            7,
        )
        .unwrap();
        let mut reg = DeviceRegistry::default();
        reg.add(cert, 100).unwrap();
        assert!(reg.is_authorized("phone-1", 100));
        assert!(reg
            .lookup_by_ed_pub(&device.public_key_bytes(), 100)
            .is_some());
        reg.revoke("phone-1");
        assert!(!reg.is_authorized("phone-1", 100));
        // Re-add after revoke must fail
        let cert2 = DeviceCertificate::issue(
            &user,
            device.public_key_bytes(),
            x,
            "phone-1",
            1,
            u64::MAX / 2,
            7,
        )
        .unwrap();
        assert!(reg.add(cert2, 100).is_err());
    }

    #[test]
    fn expired_rejected() {
        let user = Identity::generate();
        let device = Identity::generate();
        let cert = DeviceCertificate::issue(
            &user,
            device.public_key_bytes(),
            [1u8; 32],
            "old",
            1,
            50,
            0,
        )
        .unwrap();
        assert!(cert.verify(100).is_err());
    }

    #[test]
    fn registry_file_roundtrip() {
        let dir = tempdir().unwrap();
        let user = Identity::generate();
        let device = Identity::generate();
        let cert = DeviceCertificate::issue(
            &user,
            device.public_key_bytes(),
            [2u8; 32],
            "term-a",
            1,
            u64::MAX / 2,
            1,
        )
        .unwrap();
        let mut reg = DeviceRegistry::default();
        reg.add(cert, 10).unwrap();
        save_device_registry(dir.path(), &reg).unwrap();
        let loaded = load_device_registry(dir.path());
        assert!(loaded.is_authorized("term-a", 10));
    }

    #[test]
    fn shared_vector_bob_device1_signing_bytes() {
        // Parity with shared-vectors/rvn1/device_cert/bob_device1.json via records API.
        let sb = device_cert_signing_bytes(
            &hex::decode("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c").unwrap(),
            &hex::decode("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f").unwrap(),
            "bob-device-1",
            1700000000000,
            1731536000000,
            7,
        )
        .unwrap();
        assert_eq!(
            hex::encode(&sb),
            "72766e312f6465766365727400203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c0020de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f000c626f622d6465766963652d310000018bcfe5680000000193279694000000000000000007"
        );
    }
}
