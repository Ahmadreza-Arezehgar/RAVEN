//! RavenAliasRecordV1 — signed, expiring, non-unique alias claims.
//!
//! Spec: `protocol/RAVEN_ALIAS_V1.md`. Alias ≠ identity; conflicts must surface.

use crate::address::{decode_address, encode_address};
use crate::canon::{lp, u64_be};
use crate::identity::Identity;
use crate::records::alias_signing_bytes;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// V1 alias charset: lowercase a-z, digits, underscore, hyphen only.
pub fn normalize_alias(raw: &str) -> Result<String, String> {
    let s = raw.trim().trim_start_matches('@').to_lowercase();
    if s.is_empty() {
        return Err("ALIAS_EMPTY".into());
    }
    if s.len() > 64 {
        return Err("ALIAS_TOO_LONG".into());
    }
    if !s
        .chars()
        .all(|c| matches!(c, 'a'..='z' | '0'..='9' | '_' | '-'))
    {
        return Err("ALIAS_CHARSET".into());
    }
    Ok(s)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AliasRecord {
    pub alias: String,
    pub identity_address: String,
    pub sequence: u64,
    pub expires_at: u64,
    pub signature: [u8; 64],
    /// Claiming Ed25519 public key (must encode to `identity_address`).
    pub ed25519_pub: [u8; 32],
}

impl AliasRecord {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        alias_signing_bytes(
            &self.alias,
            &self.identity_address,
            self.sequence,
            self.expires_at,
        )
    }

    pub fn sign(mut self, id: &Identity) -> Result<Self, String> {
        self.ed25519_pub = id.public_key_bytes();
        self.identity_address = id.address();
        let sb = self.signing_bytes()?;
        self.signature = id.sign(&sb);
        Ok(self)
    }

    /// Verify signature, address binding, and expiry.
    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if now_ms > self.expires_at {
            return Err("ALIAS_EXPIRED".into());
        }
        let derived = encode_address(&self.ed25519_pub);
        if derived != self.identity_address {
            return Err("ALIAS_ADDR_MISMATCH".into());
        }
        if decode_address(&self.identity_address).is_none() {
            return Err("ALIAS_BAD_ADDR".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.ed25519_pub, &sb, &self.signature) {
            return Err("ALIAS_BAD_SIG".into());
        }
        Ok(())
    }

    /// Opaque DHT key for exact-alias index (hashed alias — not plaintext required on wire).
    pub fn dht_key(alias_normalized: &str) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(b"raven/alias/v1");
        h.update(alias_normalized.as_bytes());
        h.finalize().into()
    }

    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        out.extend(lp(self.alias.as_bytes())?);
        out.extend(lp(self.identity_address.as_bytes())?);
        out.extend_from_slice(&u64_be(self.sequence));
        out.extend_from_slice(&u64_be(self.expires_at));
        out.extend_from_slice(&self.ed25519_pub);
        out.extend_from_slice(&self.signature);
        Ok(out)
    }

    pub fn decode(raw: &[u8]) -> Result<Self, String> {
        if raw.len() < 2 + 2 + 8 + 8 + 32 + 64 {
            return Err("alias record short".into());
        }
        let a_len = u16::from_be_bytes([raw[0], raw[1]]) as usize;
        let mut off = 2;
        if raw.len() < off + a_len + 2 {
            return Err("alias truncated".into());
        }
        let alias = String::from_utf8(raw[off..off + a_len].to_vec())
            .map_err(|_| "alias utf8".to_string())?;
        off += a_len;
        let i_len = u16::from_be_bytes([raw[off], raw[off + 1]]) as usize;
        off += 2;
        if raw.len() < off + i_len + 8 + 8 + 32 + 64 {
            return Err("alias truncated2".into());
        }
        let identity_address = String::from_utf8(raw[off..off + i_len].to_vec())
            .map_err(|_| "addr utf8".to_string())?;
        off += i_len;
        let sequence = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        let expires_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        let mut ed25519_pub = [0u8; 32];
        ed25519_pub.copy_from_slice(&raw[off..off + 32]);
        off += 32;
        let mut signature = [0u8; 64];
        signature.copy_from_slice(&raw[off..off + 64]);
        Ok(Self {
            alias,
            identity_address,
            sequence,
            expires_at,
            signature,
            ed25519_pub,
        })
    }
}

/// Per-publisher Sybil / rate limits for public alias publication.
#[derive(Debug, Clone)]
pub struct AliasPublishQuota {
    pub max_live_claims_per_pub: usize,
    pub max_publishes_per_window: usize,
    pub window_ms: u64,
}

impl Default for AliasPublishQuota {
    fn default() -> Self {
        Self {
            max_live_claims_per_pub: 8,
            max_publishes_per_window: 16,
            window_ms: 3_600_000,
        }
    }
}

#[derive(Default)]
struct PubStats {
    live: usize,
    window_start_ms: u64,
    publishes_in_window: usize,
}

/// In-process alias claim store (community/manual peer DHT stand-in).
///
/// Keyed by `(alias, identity_address)` with LWW by `sequence`. Multiple live
/// claims for the same alias are retained and surfaced as conflicts.
#[derive(Default)]
pub struct AliasClaimStore {
    /// (normalized_alias, identity_address) → record
    claims: HashMap<(String, String), AliasRecord>,
    stats: HashMap<[u8; 32], PubStats>,
    pub quota: AliasPublishQuota,
}

impl AliasClaimStore {
    pub fn with_quota(quota: AliasPublishQuota) -> Self {
        Self {
            quota,
            ..Default::default()
        }
    }

    pub fn put(&mut self, rec: AliasRecord, now_ms: u64) -> Result<(), String> {
        let alias = normalize_alias(&rec.alias)?;
        let mut rec = rec;
        rec.alias = alias.clone();
        rec.verify(now_ms)?;

        let key = (alias, rec.identity_address.clone());
        if let Some(prev) = self.claims.get(&key) {
            if rec.sequence <= prev.sequence {
                return Err("ALIAS_STALE_SEQUENCE".into());
            }
        }

        let pubk = rec.ed25519_pub;
        let stats = self.stats.entry(pubk).or_insert(PubStats {
            live: 0,
            window_start_ms: now_ms,
            publishes_in_window: 0,
        });
        if now_ms.saturating_sub(stats.window_start_ms) > self.quota.window_ms {
            stats.window_start_ms = now_ms;
            stats.publishes_in_window = 0;
        }
        if stats.publishes_in_window >= self.quota.max_publishes_per_window {
            return Err("ALIAS_RATE_LIMIT".into());
        }
        let is_new_live = !self.claims.contains_key(&key);
        if is_new_live && stats.live >= self.quota.max_live_claims_per_pub {
            return Err("ALIAS_SYBIL_QUOTA".into());
        }

        if is_new_live {
            stats.live += 1;
        }
        stats.publishes_in_window += 1;
        self.claims.insert(key, rec);
        Ok(())
    }

    /// All live, verified claims for an exact alias (conflict set).
    pub fn lookup_exact(&self, alias_raw: &str, now_ms: u64) -> Result<Vec<AliasRecord>, String> {
        let alias = normalize_alias(alias_raw)?;
        let mut out = Vec::new();
        for ((a, _), rec) in &self.claims {
            if a == &alias && rec.verify(now_ms).is_ok() {
                out.push(rec.clone());
            }
        }
        out.sort_by(|x, y| x.identity_address.cmp(&y.identity_address));
        Ok(out)
    }

    pub fn len(&self) -> usize {
        self.claims.len()
    }

    pub fn is_empty(&self) -> bool {
        self.claims.is_empty()
    }

    /// Fixture scan helper: reject if any stored claim embeds phone/email markers.
    pub fn contains_phone_or_email_marker(&self) -> bool {
        for rec in self.claims.values() {
            let a = rec.alias.to_lowercase();
            if a.contains('@') && a.contains('.') {
                return true;
            }
            if a.chars().filter(|c| c.is_ascii_digit()).count() >= 10 {
                return true;
            }
            if a.contains("phone") || a.contains("email") || a.contains("tel:") {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_rejects_bad_charset() {
        assert!(normalize_alias("Poline!").is_err());
        assert_eq!(normalize_alias("@Poline").unwrap(), "poline");
        assert_eq!(normalize_alias("a_b-1").unwrap(), "a_b-1");
    }

    #[test]
    fn conflict_set_both_claims() {
        let a = Identity::generate();
        let b = Identity::generate();
        let mut store = AliasClaimStore::default();
        let r1 = AliasRecord {
            alias: "poline".into(),
            identity_address: String::new(),
            sequence: 1,
            expires_at: u64::MAX,
            signature: [0u8; 64],
            ed25519_pub: [0u8; 32],
        }
        .sign(&a)
        .unwrap();
        let r2 = AliasRecord {
            alias: "poline".into(),
            identity_address: String::new(),
            sequence: 1,
            expires_at: u64::MAX,
            signature: [0u8; 64],
            ed25519_pub: [0u8; 32],
        }
        .sign(&b)
        .unwrap();
        store.put(r1, 1).unwrap();
        store.put(r2, 1).unwrap();
        let hits = store.lookup_exact("@poline", 1).unwrap();
        assert_eq!(hits.len(), 2);
    }
}
