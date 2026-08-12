//! RavenStoreObjectV1 — opaque custody + rotating mailbox tags.
//!
//! Spec: `protocol/RAVEN_STORE_OBJECT_V1.md`

use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::internet::opaque_store_tag;
use crate::identity::Identity;

type HmacSha256 = Hmac<Sha256>;

pub const STORE_MAGIC: &[u8; 4] = b"RSO1";
pub const MAILBOX_LABEL: &[u8] = b"rvn1/mailbox";
pub const CUSTODY_DOMAIN: &[u8] = b"rvn1/store-custody";
pub const MAX_ENVELOPE_LEN: usize = 1_048_576;
pub const FLAG_CUSTODY_SIG: u16 = 1 << 0;

/// mailbox_tag = HMAC-SHA256(K_route, "rvn1/mailbox" || epoch || slot)[:16]
pub fn mailbox_tag(k_route: &[u8], epoch: u64, slot: u64) -> [u8; 16] {
    let mut mac = HmacSha256::new_from_slice(k_route).expect("HMAC key");
    mac.update(MAILBOX_LABEL);
    mac.update(&epoch.to_be_bytes());
    mac.update(&slot.to_be_bytes());
    let full = mac.finalize().into_bytes();
    let mut out = [0u8; 16];
    out.copy_from_slice(&full[..16]);
    out
}

/// Accept current and previous epoch (clock-skew overlap).
pub fn mailbox_tags_with_overlap(k_route: &[u8], epoch: u64, slot: u64) -> [[u8; 16]; 2] {
    let cur = mailbox_tag(k_route, epoch, slot);
    let prev = if epoch == 0 {
        cur
    } else {
        mailbox_tag(k_route, epoch - 1, slot)
    };
    [cur, prev]
}

/// Public store index key from mailbox tag (never a username).
pub fn store_tag_from_mailbox(mailbox: &[u8; 16]) -> [u8; 16] {
    opaque_store_tag(mailbox)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreObject {
    pub store_tag: [u8; 16],
    pub message_id: [u8; 16],
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub flags: u16,
    pub packed_envelope: Vec<u8>,
    pub custody_sig: Option<[u8; 64]>,
}

impl StoreObject {
    pub fn pack_unsigned(&self) -> Result<Vec<u8>, String> {
        if self.packed_envelope.len() > MAX_ENVELOPE_LEN {
            return Err("envelope too large".into());
        }
        let mut out = Vec::with_capacity(4 + 1 + 16 + 16 + 8 + 8 + 2 + 4 + self.packed_envelope.len());
        out.extend_from_slice(STORE_MAGIC);
        out.push(1);
        out.extend_from_slice(&self.store_tag);
        out.extend_from_slice(&self.message_id);
        out.extend_from_slice(&self.created_at_ms.to_be_bytes());
        out.extend_from_slice(&self.expires_at_ms.to_be_bytes());
        // Pack without custody bit for signing base.
        let flags_nosig = self.flags & !FLAG_CUSTODY_SIG;
        out.extend_from_slice(&flags_nosig.to_be_bytes());
        out.extend_from_slice(&(self.packed_envelope.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.packed_envelope);
        Ok(out)
    }

    pub fn sign_custody(&mut self, store_id: &Identity) -> Result<(), String> {
        let base = self.pack_unsigned()?;
        let mut msg = CUSTODY_DOMAIN.to_vec();
        msg.extend_from_slice(&base);
        let sig = store_id.sign(&msg);
        self.custody_sig = Some(sig);
        self.flags |= FLAG_CUSTODY_SIG;
        Ok(())
    }

    pub fn pack(&self) -> Result<Vec<u8>, String> {
        let mut out = self.pack_unsigned()?;
        if let Some(sig) = self.custody_sig {
            // Rewrite flags with custody bit.
            let flag_off = 4 + 1 + 16 + 16 + 8 + 8;
            out[flag_off..flag_off + 2].copy_from_slice(&self.flags.to_be_bytes());
            out.extend_from_slice(&sig);
        }
        Ok(out)
    }

    pub fn unpack(raw: &[u8]) -> Result<Self, String> {
        if raw.len() < 4 + 1 + 16 + 16 + 8 + 8 + 2 + 4 {
            return Err("short store object".into());
        }
        if &raw[0..4] != STORE_MAGIC {
            return Err("bad magic".into());
        }
        if raw[4] != 1 {
            return Err("version".into());
        }
        let mut store_tag = [0u8; 16];
        store_tag.copy_from_slice(&raw[5..21]);
        let mut message_id = [0u8; 16];
        message_id.copy_from_slice(&raw[21..37]);
        let created_at_ms = u64::from_be_bytes(raw[37..45].try_into().unwrap());
        let expires_at_ms = u64::from_be_bytes(raw[45..53].try_into().unwrap());
        let flags = u16::from_be_bytes([raw[53], raw[54]]);
        let elen = u32::from_be_bytes([raw[55], raw[56], raw[57], raw[58]]) as usize;
        if elen > MAX_ENVELOPE_LEN {
            return Err("envelope too large".into());
        }
        let start = 59;
        let end = start + elen;
        if raw.len() < end {
            return Err("truncated envelope".into());
        }
        let packed_envelope = raw[start..end].to_vec();
        let custody_sig = if flags & FLAG_CUSTODY_SIG != 0 {
            if raw.len() < end + 64 {
                return Err("missing custody sig".into());
            }
            let mut s = [0u8; 64];
            s.copy_from_slice(&raw[end..end + 64]);
            Some(s)
        } else {
            None
        };
        Ok(Self {
            store_tag,
            message_id,
            created_at_ms,
            expires_at_ms,
            flags,
            packed_envelope,
            custody_sig,
        })
    }

    pub fn verify_custody(&self, store_pub: &[u8; 32]) -> bool {
        let Some(sig) = self.custody_sig else {
            return false;
        };
        let Ok(base) = self.pack_unsigned() else {
            return false;
        };
        let mut msg = CUSTODY_DOMAIN.to_vec();
        msg.extend_from_slice(&base);
        Identity::verify(store_pub, &msg, &sig)
    }

    pub fn expired(&self, now_ms: u64) -> bool {
        now_ms >= self.expires_at_ms
    }
}

/// In-memory mailbox indexed by store_tag (software substitute for multi-node store).
#[derive(Default)]
pub struct StoreMailbox {
    items: Vec<StoreObject>,
    max_per_tag: usize,
}

impl StoreMailbox {
    pub fn new(max_per_tag: usize) -> Self {
        Self {
            items: Vec::new(),
            max_per_tag: max_per_tag.max(1),
        }
    }

    pub fn put(&mut self, obj: StoreObject) -> Result<(), String> {
        if obj.expired(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
        ) {
            return Err("STORE_EXPIRED".into());
        }
        let count = self
            .items
            .iter()
            .filter(|i| i.store_tag == obj.store_tag)
            .count();
        if count >= self.max_per_tag {
            return Err("STORE_FULL".into());
        }
        // Dedup by message_id under same tag.
        if self
            .items
            .iter()
            .any(|i| i.store_tag == obj.store_tag && i.message_id == obj.message_id)
        {
            return Ok(());
        }
        self.items.push(obj);
        Ok(())
    }

    pub fn get(&self, store_tag: &[u8; 16], now_ms: u64) -> Vec<&StoreObject> {
        self.items
            .iter()
            .filter(|i| i.store_tag == *store_tag && !i.expired(now_ms))
            .collect()
    }

    pub fn purge_expired(&mut self, now_ms: u64) -> usize {
        let before = self.items.len();
        self.items.retain(|i| !i.expired(now_ms));
        before - self.items.len()
    }

    pub fn delete_message(&mut self, message_id: &[u8; 16]) -> bool {
        let before = self.items.len();
        self.items.retain(|i| i.message_id != *message_id);
        before != self.items.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mailbox_rotates_and_unlinks() {
        let k: Vec<u8> = (0u8..32).collect();
        let a = mailbox_tag(&k, 100, 0);
        let b = mailbox_tag(&k, 100, 1);
        let c = mailbox_tag(&k, 101, 0);
        assert_ne!(a, b);
        assert_ne!(a, c);
        let st = store_tag_from_mailbox(&a);
        assert_ne!(st, a);
    }

    #[test]
    fn mailbox_tag_matches_shared_vector() {
        let k: Vec<u8> = (0u8..32).collect();
        let tag = mailbox_tag(&k, 1_700_000_000, 0);
        assert_eq!(hex::encode(tag), "cb693b77e3f986fe8394872d73f35428");
        assert_eq!(
            hex::encode(store_tag_from_mailbox(&tag)),
            "648ba67cde1b71c8257b0c7e3c8315b3"
        );
    }

    #[test]
    fn overlap_includes_prev_epoch() {
        let k = [9u8; 32];
        let [cur, prev] = mailbox_tags_with_overlap(&k, 5, 0);
        assert_eq!(cur, mailbox_tag(&k, 5, 0));
        assert_eq!(prev, mailbox_tag(&k, 4, 0));
    }

    #[test]
    fn store_object_roundtrip_with_custody() {
        let id = Identity::generate();
        let mut obj = StoreObject {
            store_tag: [1u8; 16],
            message_id: [2u8; 16],
            created_at_ms: 1,
            expires_at_ms: u64::MAX,
            flags: 0,
            packed_envelope: b"RVN1opaque".to_vec(),
            custody_sig: None,
        };
        obj.sign_custody(&id).unwrap();
        let packed = obj.pack().unwrap();
        let got = StoreObject::unpack(&packed).unwrap();
        assert_eq!(got.packed_envelope, b"RVN1opaque");
        assert!(got.verify_custody(&id.public_key_bytes()));
    }

    #[test]
    fn mailbox_put_get_purge() {
        let mut mb = StoreMailbox::new(2);
        let obj = StoreObject {
            store_tag: [3u8; 16],
            message_id: [4u8; 16],
            created_at_ms: 1,
            expires_at_ms: 9_000_000_000_000,
            flags: 0,
            packed_envelope: vec![1, 2, 3],
            custody_sig: None,
        };
        mb.put(obj).unwrap();
        assert_eq!(mb.get(&[3u8; 16], 50).len(), 1);
        // Force-expire by replacing with short TTL object via delete + put
        mb.delete_message(&[4u8; 16]);
        let expired = StoreObject {
            store_tag: [3u8; 16],
            message_id: [5u8; 16],
            created_at_ms: 1,
            expires_at_ms: 100,
            flags: 0,
            packed_envelope: vec![1, 2, 3],
            custody_sig: None,
        };
        // Bypass put()'s wall-clock check by pushing via get/purge path:
        mb.items.push(expired);
        assert!(mb.get(&[3u8; 16], 100).is_empty());
        assert_eq!(mb.purge_expired(100), 1);
    }
}
