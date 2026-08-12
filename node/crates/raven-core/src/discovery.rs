//! Signed peer discovery records (DHT-ready).
//!
//! Spec: `protocol/RAVEN_TRANSPORT_INTERFACE_V1.md`
//! Live rust-libp2p Kademlia publish/lookup remains optional; this module
//! provides the authenticated value format and an in-process store used by
//! software substitutes for NAT/DHT hardware proofs.

use crate::canon::{lp, u64_be};
use crate::identity::Identity;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub const PEER_DOMAIN: &[u8] = b"rvn1/peer";
pub const ALIAS_HINT_DOMAIN: &[u8] = b"rvn1/peer-alias-hint";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerRecord {
    /// UTF-8 multiaddr or `host:port` dial string (no secrets).
    pub dial: String,
    pub ed25519_pub: [u8; 32],
    pub caps: u32,
    pub expires_at_ms: u64,
    pub signature: [u8; 64],
}

impl PeerRecord {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        let mut out = PEER_DOMAIN.to_vec();
        out.extend(lp(self.dial.as_bytes())?);
        out.extend_from_slice(&self.ed25519_pub);
        out.extend_from_slice(&self.caps.to_be_bytes());
        out.extend_from_slice(&u64_be(self.expires_at_ms));
        Ok(out)
    }

    pub fn sign(mut self, id: &Identity) -> Result<Self, String> {
        self.ed25519_pub = id.public_key_bytes();
        let sb = self.signing_bytes()?;
        self.signature = id.sign(&sb);
        Ok(self)
    }

    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if now_ms > self.expires_at_ms {
            return Err("PEER_EXPIRED".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.ed25519_pub, &sb, &self.signature) {
            return Err("PEER_BAD_SIG".into());
        }
        Ok(())
    }

    /// DHT key: SHA-256("rvn1/peer-key" || ed25519_pub) — not a username.
    pub fn dht_key(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(b"rvn1/peer-key");
        h.update(self.ed25519_pub);
        h.finalize().into()
    }
}

/// Opaque alias→identity hint for gossip (alias bytes hashed; not plaintext index required).
pub fn alias_hint_key(alias_normalized: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(ALIAS_HINT_DOMAIN);
    h.update(alias_normalized.as_bytes());
    h.finalize().into()
}

/// In-process DHT stand-in (software substitute for live Kademlia).
#[derive(Default)]
pub struct DiscoveryStore {
    peers: HashMap<[u8; 32], PeerRecord>,
}

impl DiscoveryStore {
    pub fn put(&mut self, rec: PeerRecord, now_ms: u64) -> Result<(), String> {
        rec.verify(now_ms)?;
        self.peers.insert(rec.dht_key(), rec);
        Ok(())
    }

    pub fn get(&self, key: &[u8; 32], now_ms: u64) -> Option<&PeerRecord> {
        let r = self.peers.get(key)?;
        r.verify(now_ms).ok()?;
        Some(r)
    }

    pub fn lookup_pub(&self, ed25519_pub: &[u8; 32], now_ms: u64) -> Option<&PeerRecord> {
        let mut h = Sha256::new();
        h.update(b"rvn1/peer-key");
        h.update(ed25519_pub);
        let key: [u8; 32] = h.finalize().into();
        self.get(&key, now_ms)
    }

    pub fn len(&self) -> usize {
        self.peers.len()
    }
}

/// Documented NAT / CGNAT status for checklist honesty.
pub const NAT_STATUS: &str = "BLOCKED_HARDWARE: multi-NAT/CGNAT/DCUtR live matrix not run; \
software substitutes: DiscoveryStore + internet_dial_smoke + lan_path_smoke";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_record_roundtrip_store() {
        let id = Identity::generate();
        let rec = PeerRecord {
            dial: "127.0.0.1:7000".into(),
            ed25519_pub: [0u8; 32],
            caps: 0b10,
            expires_at_ms: u64::MAX,
            signature: [0u8; 64],
        }
        .sign(&id)
        .unwrap();
        let mut store = DiscoveryStore::default();
        store.put(rec.clone(), 1).unwrap();
        let got = store.lookup_pub(&id.public_key_bytes(), 1).unwrap();
        assert_eq!(got.dial, "127.0.0.1:7000");
    }

    #[test]
    fn tampered_peer_rejected() {
        let id = Identity::generate();
        let mut rec = PeerRecord {
            dial: "/ip4/1.2.3.4/tcp/9".into(),
            ed25519_pub: [0u8; 32],
            caps: 1,
            expires_at_ms: u64::MAX,
            signature: [0u8; 64],
        }
        .sign(&id)
        .unwrap();
        rec.dial = "evil".into();
        assert!(rec.verify(1).is_err());
    }

    #[test]
    fn nat_status_mentions_blocked_hardware() {
        assert!(NAT_STATUS.contains("BLOCKED_HARDWARE"));
    }
}
