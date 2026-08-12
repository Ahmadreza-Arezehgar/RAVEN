//! Multi-device contact sync + signed revocation propagation (§39).
//!
//! Software-feasible subset:
//! - Encrypt device-to-device contact sync with a user-identity-derived key
//!   (no central plaintext store).
//! - Signed `RevocationRecord` with monotonic epoch; merge is denylist-sticky.
//! - Partition tests: revoked device cannot re-add; partitioned peer may lag
//!   until it observes a higher-epoch revocation (documented limitation).
//!
//! Not in V1 wire gossip: live network push of revocation (no dedicated DHT
//! record type frozen yet). Callers exchange sealed blobs / records OOB or
//! via opaque store-carry.

use crate::device_cert::DeviceRegistry;
use crate::identity::Identity;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;

const SYNC_MAGIC: &[u8; 8] = b"RDCS1\0\0\0"; // Raven Device Contact Sync v1
const SYNC_INFO: &[u8] = b"raven/rvn1/device-sync/contacts/v1";
const REVOKE_DOMAIN: &[u8] = b"rvn1/devrevoke/v1";

/// Public contact fields only — never private keys.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncContact {
    pub alias: String,
    pub address: String,
    pub pub_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContactSyncPlaintext {
    pub schema: u32,
    pub from_device_id: String,
    pub contacts: Vec<SyncContact>,
    pub issued_at_ms: u64,
}

/// User-identity-signed device revocation (local + exchangeable).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RevocationRecord {
    pub schema: u32,
    pub user_ed_pub_hex: String,
    pub device_id: String,
    /// Monotonic per-user epoch; higher wins on merge.
    pub epoch: u64,
    pub issued_at_ms: u64,
    pub reason: String,
    pub signature_hex: String,
}

impl RevocationRecord {
    pub fn issue(
        user: &Identity,
        device_id: impl Into<String>,
        epoch: u64,
        issued_at_ms: u64,
        reason: impl Into<String>,
    ) -> Result<Self, String> {
        let device_id = device_id.into();
        let reason = reason.into();
        let user_ed = user.public_key_bytes();
        let sb = revocation_signing_bytes(&user_ed, &device_id, epoch, issued_at_ms, &reason);
        let signature = user.sign(&sb);
        Ok(Self {
            schema: 1,
            user_ed_pub_hex: hex::encode(user_ed),
            device_id,
            epoch,
            issued_at_ms,
            reason,
            signature_hex: hex::encode(signature),
        })
    }

    pub fn verify(&self) -> Result<(), String> {
        if self.schema != 1 {
            return Err("REVOKE_SCHEMA".into());
        }
        let user_ed = decode_32_hex(&self.user_ed_pub_hex)?;
        let sig = decode_64_hex(&self.signature_hex)?;
        let sb = revocation_signing_bytes(
            &user_ed,
            &self.device_id,
            self.epoch,
            self.issued_at_ms,
            &self.reason,
        );
        if !Identity::verify(&user_ed, &sb, &sig) {
            return Err("REVOKE_BAD_SIG".into());
        }
        Ok(())
    }
}

fn revocation_signing_bytes(
    user_ed: &[u8; 32],
    device_id: &str,
    epoch: u64,
    issued_at_ms: u64,
    reason: &str,
) -> Vec<u8> {
    let mut v = Vec::with_capacity(128);
    v.extend_from_slice(REVOKE_DOMAIN);
    v.extend_from_slice(user_ed);
    v.extend_from_slice(&(device_id.len() as u32).to_be_bytes());
    v.extend_from_slice(device_id.as_bytes());
    v.extend_from_slice(&epoch.to_be_bytes());
    v.extend_from_slice(&issued_at_ms.to_be_bytes());
    v.extend_from_slice(&(reason.len() as u32).to_be_bytes());
    v.extend_from_slice(reason.as_bytes());
    v
}

fn decode_32_hex(s: &str) -> Result<[u8; 32], String> {
    let v = hex::decode(s).map_err(|e| e.to_string())?;
    if v.len() != 32 {
        return Err("expected 32 bytes".into());
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

fn decode_64_hex(s: &str) -> Result<[u8; 64], String> {
    let v = hex::decode(s).map_err(|e| e.to_string())?;
    if v.len() != 64 {
        return Err("expected 64 bytes".into());
    }
    let mut a = [0u8; 64];
    a.copy_from_slice(&v);
    Ok(a)
}

/// Derive contact-sync AEAD key from user identity seed (never printed).
pub fn derive_device_sync_key(user: &Identity) -> [u8; 32] {
    let seed = user.seed_bytes();
    let hk = Hkdf::<Sha256>::new(Some(b"raven-device-sync"), &seed);
    let mut okm = [0u8; 32];
    hk.expand(SYNC_INFO, &mut okm).expect("hkdf");
    okm
}

/// Seal contact sync for another authorized device of the same user.
pub fn seal_contact_sync(
    user: &Identity,
    plain: &ContactSyncPlaintext,
) -> Result<Vec<u8>, String> {
    let key = derive_device_sync_key(user);
    let pt = serde_json::to_vec(plain).map_err(|e| e.to_string())?;
    let cipher = ChaCha20Poly1305::new((&key).into());
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let aad = user.public_key_bytes();
    let ct = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            Payload {
                msg: &pt,
                aad: &aad,
            },
        )
        .map_err(|_| "device sync seal failed".to_string())?;
    let mut wire = Vec::with_capacity(8 + 12 + ct.len());
    wire.extend_from_slice(SYNC_MAGIC);
    wire.extend_from_slice(&nonce_bytes);
    wire.extend_from_slice(&ct);
    Ok(wire)
}

/// Unseal contact sync. Caller must ensure `from_device_id` is authorized.
pub fn unseal_contact_sync(
    user: &Identity,
    wire: &[u8],
) -> Result<ContactSyncPlaintext, String> {
    if wire.len() < 8 + 12 + 16 {
        return Err("truncated device sync".into());
    }
    if &wire[..8] != SYNC_MAGIC {
        return Err("bad device sync magic".into());
    }
    let key = derive_device_sync_key(user);
    let nonce = Nonce::from_slice(&wire[8..20]);
    let ct = &wire[20..];
    let aad = user.public_key_bytes();
    let cipher = ChaCha20Poly1305::new((&key).into());
    let pt = cipher
        .decrypt(
            nonce,
            Payload {
                msg: ct,
                aad: &aad,
            },
        )
        .map_err(|_| "device sync unseal failed".to_string())?;
    serde_json::from_slice(&pt).map_err(|e| e.to_string())
}

/// Apply sealed sync only if source device is authorized in the local registry.
pub fn import_contact_sync(
    user: &Identity,
    registry: &DeviceRegistry,
    wire: &[u8],
    now_ms: u64,
) -> Result<Vec<SyncContact>, String> {
    let plain = unseal_contact_sync(user, wire)?;
    if !registry.is_authorized(&plain.from_device_id, now_ms) {
        return Err("SYNC_FROM_UNAUTHORIZED_OR_REVOKED".into());
    }
    if plain.schema != 1 {
        return Err("SYNC_SCHEMA".into());
    }
    Ok(plain.contacts)
}

/// Merge revocation records: sticky denylist; higher epoch wins per device_id.
#[derive(Debug, Default, Clone)]
pub struct RevocationStore {
    /// device_id → best (highest epoch) verified record
    by_device: HashMap<String, RevocationRecord>,
}

impl RevocationStore {
    pub fn apply(&mut self, rec: RevocationRecord) -> Result<bool, String> {
        rec.verify()?;
        match self.by_device.get(&rec.device_id) {
            Some(prev) if prev.epoch > rec.epoch => Ok(false),
            Some(prev) if prev.epoch == rec.epoch => {
                // Same epoch: accept if identical; reject conflicting payloads.
                if prev == &rec {
                    Ok(false)
                } else {
                    Err("REVOKE_EPOCH_CONFLICT".into())
                }
            }
            _ => {
                self.by_device.insert(rec.device_id.clone(), rec);
                Ok(true)
            }
        }
    }

    pub fn is_revoked(&self, device_id: &str) -> bool {
        self.by_device.contains_key(device_id)
    }

    pub fn epoch_of(&self, device_id: &str) -> Option<u64> {
        self.by_device.get(device_id).map(|r| r.epoch)
    }

    /// Apply into a DeviceRegistry (local denylist).
    pub fn push_into_registry(&self, reg: &mut DeviceRegistry) {
        for id in self.by_device.keys() {
            reg.revoke(id);
        }
    }

    pub fn records(&self) -> impl Iterator<Item = &RevocationRecord> {
        self.by_device.values()
    }
}

/// Partition limitation: without observing a revocation, a peer may still
/// treat a device as authorized. Software test models lagging replica B.
pub fn partition_lag_allows_stale_auth(
    fresh: &DeviceRegistry,
    lagging: &DeviceRegistry,
    device_id: &str,
    now_ms: u64,
) -> bool {
    !fresh.is_authorized(device_id, now_ms) && lagging.is_authorized(device_id, now_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_cert::DeviceCertificate;

    fn issue_phone(user: &Identity, id: &str) -> DeviceCertificate {
        let device = Identity::generate();
        DeviceCertificate::issue(
            user,
            device.public_key_bytes(),
            [3u8; 32],
            id,
            1,
            u64::MAX / 2,
            1,
        )
        .unwrap()
    }

    #[test]
    fn encrypted_contact_sync_roundtrip() {
        let user = Identity::generate();
        let mut reg = DeviceRegistry::default();
        reg.add(issue_phone(&user, "phone-a"), 100).unwrap();
        let plain = ContactSyncPlaintext {
            schema: 1,
            from_device_id: "phone-a".into(),
            contacts: vec![SyncContact {
                alias: "bob".into(),
                address: "rvn1qqqq".into(),
                pub_hex: "aa".into(),
            }],
            issued_at_ms: 100,
        };
        let wire = seal_contact_sync(&user, &plain).unwrap();
        assert!(wire.starts_with(SYNC_MAGIC));
        let got = import_contact_sync(&user, &reg, &wire, 100).unwrap();
        assert_eq!(got, plain.contacts);
    }

    #[test]
    fn revoked_device_cannot_push_sync() {
        let user = Identity::generate();
        let mut reg = DeviceRegistry::default();
        reg.add(issue_phone(&user, "phone-lost"), 100).unwrap();
        let plain = ContactSyncPlaintext {
            schema: 1,
            from_device_id: "phone-lost".into(),
            contacts: vec![],
            issued_at_ms: 100,
        };
        let wire = seal_contact_sync(&user, &plain).unwrap();
        reg.revoke("phone-lost");
        assert_eq!(
            import_contact_sync(&user, &reg, &wire, 100).unwrap_err(),
            "SYNC_FROM_UNAUTHORIZED_OR_REVOKED"
        );
    }

    #[test]
    fn revoked_cannot_add_another_device() {
        let user = Identity::generate();
        let mut reg = DeviceRegistry::default();
        reg.add(issue_phone(&user, "term-1"), 100).unwrap();
        reg.revoke("term-1");
        // After revoke, registry refuses re-add of same id (sticky denylist).
        assert!(reg.add(issue_phone(&user, "term-1"), 100).is_err());
        // A separate "issuer" check: revoked devices are not authorized, so
        // policy layer must refuse using them as co-signers — modeled here as
        // is_authorized == false before any add-device UX.
        assert!(!reg.is_authorized("term-1", 100));
    }

    #[test]
    fn revocation_record_merge_and_partition_lag() {
        let user = Identity::generate();
        let mut fresh = DeviceRegistry::default();
        let mut lagging = DeviceRegistry::default();
        let cert = issue_phone(&user, "stolen");
        fresh.add(cert.clone(), 50).unwrap();
        lagging.add(cert, 50).unwrap();

        let rec = RevocationRecord::issue(&user, "stolen", 2, 60, "lost").unwrap();
        let mut store = RevocationStore::default();
        assert!(store.apply(rec.clone()).unwrap());
        store.push_into_registry(&mut fresh);

        assert!(partition_lag_allows_stale_auth(&fresh, &lagging, "stolen", 70));

        // Lagging eventually observes the record.
        let mut store_b = RevocationStore::default();
        assert!(store_b.apply(rec).unwrap());
        // Older epoch ignored
        let older = RevocationRecord::issue(&user, "stolen", 1, 55, "old").unwrap();
        assert!(!store_b.apply(older).unwrap());
        store_b.push_into_registry(&mut lagging);
        assert!(!partition_lag_allows_stale_auth(
            &fresh, &lagging, "stolen", 70
        ));
        assert!(!lagging.is_authorized("stolen", 70));
    }

    #[test]
    fn wrong_user_key_fails_unseal() {
        let a = Identity::generate();
        let b = Identity::generate();
        let plain = ContactSyncPlaintext {
            schema: 1,
            from_device_id: "x".into(),
            contacts: vec![],
            issued_at_ms: 1,
        };
        let wire = seal_contact_sync(&a, &plain).unwrap();
        assert!(unseal_contact_sync(&b, &wire).is_err());
    }
}
