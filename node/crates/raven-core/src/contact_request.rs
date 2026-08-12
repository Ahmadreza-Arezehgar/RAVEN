//! RavenContactRequestV1 + ContactAcceptV1 — E2EE async via prekey / pairwise seal.
//!
//! Delivered as opaque RavenEnvelopeV1 message bodies through MessageRouter
//! (direct / relay / store / BLE / Bridge). Bridge never decrypts.

use crate::canon::{lp, u64_be};
use crate::identity::Identity;
use crate::seal::{derive_pairwise_key, seal_message, unseal_message};
use sha2::{Digest, Sha256};

pub const CONTACT_REQ_DOMAIN: &[u8] = b"rvn1/contact-req";
pub const CONTACT_ACCEPT_DOMAIN: &[u8] = b"rvn1/contact-accept";
pub const CONTACT_REQ_INNER: &[u8] = b"rvn1/contact-req-inner";

/// Cleartext fields that live *inside* the sealed payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactRequestInner {
    pub request_id: [u8; 16],
    pub sender_raven_id: String,
    pub sender_display_name: String,
    pub sender_aliases: Vec<String>,
    pub sender_profile_digest: [u8; 32],
    pub optional_message: String,
    pub created_at: u64,
    pub expires_at: u64,
}

impl ContactRequestInner {
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let mut out = CONTACT_REQ_INNER.to_vec();
        out.extend_from_slice(&self.request_id);
        out.extend(lp(self.sender_raven_id.as_bytes())?);
        out.extend(lp(self.sender_display_name.as_bytes())?);
        out.extend_from_slice(&(self.sender_aliases.len() as u16).to_be_bytes());
        for a in &self.sender_aliases {
            out.extend(lp(a.as_bytes())?);
        }
        out.extend_from_slice(&self.sender_profile_digest);
        out.extend(lp(self.optional_message.as_bytes())?);
        out.extend_from_slice(&u64_be(self.created_at));
        out.extend_from_slice(&u64_be(self.expires_at));
        Ok(out)
    }

    pub fn decode(raw: &[u8]) -> Result<Self, String> {
        if raw.len() < CONTACT_REQ_INNER.len() + 16 {
            return Err("contact req inner short".into());
        }
        if &raw[..CONTACT_REQ_INNER.len()] != CONTACT_REQ_INNER {
            return Err("contact req inner magic".into());
        }
        let mut off = CONTACT_REQ_INNER.len();
        let mut request_id = [0u8; 16];
        request_id.copy_from_slice(&raw[off..off + 16]);
        off += 16;
        let (sender_raven_id, n) = read_lp_str(raw, off)?;
        off = n;
        let (sender_display_name, n) = read_lp_str(raw, off)?;
        off = n;
        if off + 2 > raw.len() {
            return Err("aliases len".into());
        }
        let n_alias = u16::from_be_bytes([raw[off], raw[off + 1]]) as usize;
        off += 2;
        let mut sender_aliases = Vec::with_capacity(n_alias);
        for _ in 0..n_alias {
            let (a, n) = read_lp_str(raw, off)?;
            off = n;
            sender_aliases.push(a);
        }
        if off + 32 > raw.len() {
            return Err("digest".into());
        }
        let mut sender_profile_digest = [0u8; 32];
        sender_profile_digest.copy_from_slice(&raw[off..off + 32]);
        off += 32;
        let (optional_message, n) = read_lp_str(raw, off)?;
        off = n;
        if off + 16 > raw.len() {
            return Err("timestamps".into());
        }
        let created_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        let expires_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        Ok(Self {
            request_id,
            sender_raven_id,
            sender_display_name,
            sender_aliases,
            sender_profile_digest,
            optional_message,
            created_at,
            expires_at,
        })
    }
}

fn read_lp_str(raw: &[u8], off: usize) -> Result<(String, usize), String> {
    if off + 2 > raw.len() {
        return Err("lp short".into());
    }
    let len = u16::from_be_bytes([raw[off], raw[off + 1]]) as usize;
    let start = off + 2;
    if start + len > raw.len() {
        return Err("lp trunc".into());
    }
    let s = String::from_utf8(raw[start..start + len].to_vec()).map_err(|_| "utf8".to_string())?;
    Ok((s, start + len))
}

/// Wire object: sealed contact request (ciphertext-only for store/bridge).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RavenContactRequestV1 {
    pub request_id: [u8; 16],
    pub recipient_raven_id: String,
    pub created_at: u64,
    pub expires_at: u64,
    /// Opaque sealed body — Bridge/store MUST NOT decrypt.
    pub ciphertext: Vec<u8>,
    pub sender_authentication: [u8; 64],
    pub sender_pub: [u8; 32],
}

impl RavenContactRequestV1 {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        let mut out = CONTACT_REQ_DOMAIN.to_vec();
        out.extend_from_slice(&self.request_id);
        out.extend(lp(self.recipient_raven_id.as_bytes())?);
        out.extend_from_slice(&u64_be(self.created_at));
        out.extend_from_slice(&u64_be(self.expires_at));
        out.extend(lp(&self.ciphertext)?);
        Ok(out)
    }

    pub fn create(
        sender: &Identity,
        recipient_pub: &[u8; 32],
        recipient_addr: &str,
        inner: ContactRequestInner,
    ) -> Result<Self, String> {
        let plain = inner.encode()?;
        let key = derive_pairwise_key(&sender.public_key_bytes(), recipient_pub);
        let ciphertext = seal_message(
            &key,
            &plain,
            &sender.address(),
            recipient_addr,
            &inner.request_id,
        )?;
        let mut req = Self {
            request_id: inner.request_id,
            recipient_raven_id: recipient_addr.to_string(),
            created_at: inner.created_at,
            expires_at: inner.expires_at,
            ciphertext,
            sender_authentication: [0u8; 64],
            sender_pub: sender.public_key_bytes(),
        };
        let sb = req.signing_bytes()?;
        req.sender_authentication = sender.sign(&sb);
        Ok(req)
    }

    pub fn verify_outer(&self, now_ms: u64) -> Result<(), String> {
        if now_ms > self.expires_at {
            return Err("CONTACT_REQ_EXPIRED".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.sender_pub, &sb, &self.sender_authentication) {
            return Err("CONTACT_REQ_BAD_SIG".into());
        }
        Ok(())
    }

    pub fn open(&self, recipient: &Identity) -> Result<ContactRequestInner, String> {
        let key = derive_pairwise_key(&self.sender_pub, &recipient.public_key_bytes());
        let sender_addr = crate::address::encode_address(&self.sender_pub);
        let plain = unseal_message(
            &key,
            &self.ciphertext,
            &sender_addr,
            &self.recipient_raven_id,
            &self.request_id,
        )?;
        ContactRequestInner::decode(&plain)
    }

    /// True when store/bridge only sees ciphertext (no plaintext markers).
    pub fn is_ciphertext_only(&self) -> bool {
        !self.ciphertext.is_empty()
            && !String::from_utf8_lossy(&self.ciphertext).contains("rvn1/contact-req-inner")
    }

    pub fn content_hash(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(&self.request_id);
        h.update(&self.ciphertext);
        h.finalize().into()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactAcceptV1 {
    pub request_id: [u8; 16],
    pub accepter_raven_id: String,
    pub requester_raven_id: String,
    pub accepted_at: u64,
    pub signature: [u8; 64],
    pub accepter_pub: [u8; 32],
}

impl ContactAcceptV1 {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        let mut out = CONTACT_ACCEPT_DOMAIN.to_vec();
        out.extend_from_slice(&self.request_id);
        out.extend(lp(self.accepter_raven_id.as_bytes())?);
        out.extend(lp(self.requester_raven_id.as_bytes())?);
        out.extend_from_slice(&u64_be(self.accepted_at));
        Ok(out)
    }

    pub fn sign(mut self, accepter: &Identity) -> Result<Self, String> {
        self.accepter_pub = accepter.public_key_bytes();
        self.accepter_raven_id = accepter.address();
        let sb = self.signing_bytes()?;
        self.signature = accepter.sign(&sb);
        Ok(self)
    }

    pub fn verify(&self) -> Result<(), String> {
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.accepter_pub, &sb, &self.signature) {
            return Err("CONTACT_ACCEPT_BAD_SIG".into());
        }
        Ok(())
    }
}
