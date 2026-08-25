//! RavenContactRequestV1 + ContactAcceptV1 — root-required ATSAM contact codec.
//!
//! Delivered as opaque RavenEnvelopeV1 message bodies through MessageRouter
//! (direct / relay / store / BLE / Bridge). Bridge never decrypts.
//!
//! Recipient opens locally into `ContactRequestInbox`, then Accept / Decline / Block.

use crate::atsam_aead::{seal_rvna1_v2, unseal_rvna1_v2};
use crate::canon::{lp, u64_be};
use crate::chat_history::BlockList;
use crate::discovery_resolver::VerificationState;
use crate::identity::Identity;
use sha2::{Digest, Sha256};

pub const CONTACT_REQ_DOMAIN: &[u8] = b"rvn1/contact-req";
pub const CONTACT_ACCEPT_DOMAIN: &[u8] = b"rvn1/contact-accept";
pub const CONTACT_REQ_INNER: &[u8] = b"rvn1/contact-req-inner";
pub const CONTACT_REQ_WIRE: &[u8] = b"rvn1/contact-req-wire";
pub const CONTACT_ACCEPT_WIRE: &[u8] = b"rvn1/contact-accept-wire";
/// Rootless contact-request encryption is intentionally unavailable. Public
/// identity keys are not secrets; callers must supply an authenticated ATSAM
/// session root through the explicit `*_with_atsam_root` APIs.
pub const CONTACT_REQ_SESSION_REQUIRED: &str =
    "CONTACT_REQ_SESSION_REQUIRED: authenticated ATSAM root required";

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
        let alias_count = u16::try_from(self.sender_aliases.len())
            .map_err(|_| "too many contact request aliases".to_string())?;
        out.extend_from_slice(&alias_count.to_be_bytes());
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
        off += 8;
        if off != raw.len() {
            return Err("contact req inner trailing bytes".into());
        }
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
        let _ = (sender, recipient_pub, recipient_addr, inner);
        Err(CONTACT_REQ_SESSION_REQUIRED.into())
    }

    /// Create a contact request under an already authenticated ATSAM session
    /// root. Session establishment, root persistence, and monotonic index
    /// allocation are the caller's responsibility.
    pub fn create_with_atsam_root(
        sender: &Identity,
        recipient_pub: &[u8; 32],
        recipient_addr: &str,
        inner: ContactRequestInner,
        root: &[u8; 32],
        chain_index: u32,
        nonce: &[u8; 12],
    ) -> Result<Self, String> {
        if crate::address::encode_address(recipient_pub) != recipient_addr {
            return Err("CONTACT_REQ_RECIPIENT_KEY_MISMATCH".into());
        }
        let sender_addr = sender.address();
        if inner.sender_raven_id != sender_addr {
            return Err("CONTACT_REQ_SENDER_ID_MISMATCH".into());
        }
        if inner.expires_at <= inner.created_at {
            return Err("CONTACT_REQ_INVALID_TIME_RANGE".into());
        }
        let plain = inner.encode()?;
        let ciphertext = seal_rvna1_v2(
            root,
            &sender_addr,
            recipient_addr,
            &hex::encode(inner.request_id),
            chain_index,
            &plain,
            nonce,
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
        req.sender_authentication = sender.sign(&req.signing_bytes()?);
        Ok(req)
    }

    pub fn verify_outer(&self, now_ms: u64) -> Result<(), String> {
        if self.expires_at <= self.created_at {
            return Err("CONTACT_REQ_INVALID_TIME_RANGE".into());
        }
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
        let _ = recipient;
        Err(CONTACT_REQ_SESSION_REQUIRED.into())
    }

    /// Open using the authenticated ATSAM session root paired with the sender.
    pub fn open_with_atsam_root(
        &self,
        recipient: &Identity,
        root: &[u8; 32],
    ) -> Result<ContactRequestInner, String> {
        if self.recipient_raven_id != recipient.address() {
            return Err("CONTACT_REQ_WRONG_RECIPIENT".into());
        }
        let sender_addr = crate::address::encode_address(&self.sender_pub);
        let plain = unseal_rvna1_v2(
            root,
            &self.ciphertext,
            &sender_addr,
            &self.recipient_raven_id,
            &hex::encode(self.request_id),
        )?;
        let inner = ContactRequestInner::decode(&plain)?;
        if inner.request_id != self.request_id
            || inner.sender_raven_id != sender_addr
            || inner.created_at != self.created_at
            || inner.expires_at != self.expires_at
        {
            return Err("CONTACT_REQ_INNER_BINDING_MISMATCH".into());
        }
        Ok(inner)
    }

    /// True when store/bridge only sees ciphertext (no plaintext markers).
    pub fn is_ciphertext_only(&self) -> bool {
        !self.ciphertext.is_empty()
            && !String::from_utf8_lossy(&self.ciphertext).contains("rvn1/contact-req-inner")
    }

    pub fn content_hash(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(self.request_id);
        h.update(&self.ciphertext);
        h.finalize().into()
    }

    /// Full outer object for MessageRouter body (ciphertext remains opaque to Bridge).
    pub fn encode_wire(&self) -> Result<Vec<u8>, String> {
        let mut out = CONTACT_REQ_WIRE.to_vec();
        out.extend_from_slice(&self.request_id);
        out.extend(lp(self.recipient_raven_id.as_bytes())?);
        out.extend_from_slice(&u64_be(self.created_at));
        out.extend_from_slice(&u64_be(self.expires_at));
        out.extend(lp(&self.ciphertext)?);
        out.extend_from_slice(&self.sender_authentication);
        out.extend_from_slice(&self.sender_pub);
        Ok(out)
    }

    pub fn decode_wire(raw: &[u8]) -> Result<Self, String> {
        if raw.len() < CONTACT_REQ_WIRE.len() + 16 + 64 + 32 {
            return Err("contact req wire short".into());
        }
        if &raw[..CONTACT_REQ_WIRE.len()] != CONTACT_REQ_WIRE {
            return Err("contact req wire magic".into());
        }
        let mut off = CONTACT_REQ_WIRE.len();
        let mut request_id = [0u8; 16];
        request_id.copy_from_slice(&raw[off..off + 16]);
        off += 16;
        let (recipient_raven_id, n) = read_lp_str(raw, off)?;
        off = n;
        if off + 16 > raw.len() {
            return Err("timestamps".into());
        }
        let created_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        let expires_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        if off + 2 > raw.len() {
            return Err("ct lp".into());
        }
        let ct_len = u16::from_be_bytes([raw[off], raw[off + 1]]) as usize;
        off += 2;
        if off + ct_len + 64 + 32 != raw.len() {
            return Err("ct trunc".into());
        }
        let ciphertext = raw[off..off + ct_len].to_vec();
        off += ct_len;
        let mut sender_authentication = [0u8; 64];
        sender_authentication.copy_from_slice(&raw[off..off + 64]);
        off += 64;
        let mut sender_pub = [0u8; 32];
        sender_pub.copy_from_slice(&raw[off..off + 32]);
        Ok(Self {
            request_id,
            recipient_raven_id,
            created_at,
            expires_at,
            ciphertext,
            sender_authentication,
            sender_pub,
        })
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

    pub fn encode_wire(&self) -> Result<Vec<u8>, String> {
        let mut out = CONTACT_ACCEPT_WIRE.to_vec();
        out.extend_from_slice(&self.request_id);
        out.extend(lp(self.accepter_raven_id.as_bytes())?);
        out.extend(lp(self.requester_raven_id.as_bytes())?);
        out.extend_from_slice(&u64_be(self.accepted_at));
        out.extend_from_slice(&self.signature);
        out.extend_from_slice(&self.accepter_pub);
        Ok(out)
    }

    pub fn decode_wire(raw: &[u8]) -> Result<Self, String> {
        if raw.len() < CONTACT_ACCEPT_WIRE.len() + 16 + 64 + 32 {
            return Err("contact accept wire short".into());
        }
        if &raw[..CONTACT_ACCEPT_WIRE.len()] != CONTACT_ACCEPT_WIRE {
            return Err("contact accept wire magic".into());
        }
        let mut off = CONTACT_ACCEPT_WIRE.len();
        let mut request_id = [0u8; 16];
        request_id.copy_from_slice(&raw[off..off + 16]);
        off += 16;
        let (accepter_raven_id, n) = read_lp_str(raw, off)?;
        off = n;
        let (requester_raven_id, n) = read_lp_str(raw, off)?;
        off = n;
        if off + 8 + 64 + 32 > raw.len() {
            return Err("accept trunc".into());
        }
        let accepted_at = u64::from_be_bytes(raw[off..off + 8].try_into().unwrap());
        off += 8;
        let mut signature = [0u8; 64];
        signature.copy_from_slice(&raw[off..off + 64]);
        off += 64;
        let mut accepter_pub = [0u8; 32];
        accepter_pub.copy_from_slice(&raw[off..off + 32]);
        Ok(Self {
            request_id,
            accepter_raven_id,
            requester_raven_id,
            accepted_at,
            signature,
            accepter_pub,
        })
    }
}

/// Opened pending request held locally until Accept / Decline / Block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingContactRequest {
    pub outer: RavenContactRequestV1,
    pub inner: ContactRequestInner,
    pub received_at: u64,
}

/// Local contact row produced on Accept (bound by Raven ID, not alias).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactBinding {
    pub raven_id: String,
    pub pub_hex: String,
    pub petname: String,
    pub verification_state: VerificationState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactAcceptOutcome {
    pub accept: ContactAcceptV1,
    pub binding: ContactBinding,
}

/// Recipient-side inbox. Opens sealed requests locally; Bridge never sees plaintext.
#[derive(Default)]
pub struct ContactRequestInbox {
    pub pending: Vec<PendingContactRequest>,
}

/// Anti-spam caps for inbound contact requests (local only — no central moderation).
pub const CONTACT_REQ_MAX_PENDING: usize = 64;
pub const CONTACT_REQ_MAX_PER_SENDER: usize = 3;
/// Rolling window for per-sender ingest rate (ms).
pub const CONTACT_REQ_SENDER_WINDOW_MS: u64 = 3_600_000; // 1h
pub const CONTACT_REQ_MAX_PER_SENDER_WINDOW: usize = 5;

impl ContactRequestInbox {
    pub fn pending(&self) -> &[PendingContactRequest] {
        &self.pending
    }

    /// Verify outer + open with recipient key; dedup on request_id.
    /// Rejects when inbox / per-sender caps are exceeded (anti-spam).
    pub fn ingest(
        &mut self,
        outer: RavenContactRequestV1,
        recipient: &Identity,
        now_ms: u64,
    ) -> Result<ContactRequestInner, String> {
        outer.verify_outer(now_ms)?;
        if outer.recipient_raven_id != recipient.address() {
            return Err("CONTACT_REQ_WRONG_RECIPIENT".into());
        }
        let inner = outer.open(recipient)?;
        self.ingest_opened(outer, inner, now_ms)
    }

    /// Verify, decrypt with an authenticated ATSAM root, then apply inbox
    /// deduplication and anti-spam policy. Failed authentication never inserts
    /// a durable request ID.
    pub fn ingest_with_atsam_root(
        &mut self,
        outer: RavenContactRequestV1,
        recipient: &Identity,
        root: &[u8; 32],
        now_ms: u64,
    ) -> Result<ContactRequestInner, String> {
        outer.verify_outer(now_ms)?;
        if outer.recipient_raven_id != recipient.address() {
            return Err("CONTACT_REQ_WRONG_RECIPIENT".into());
        }
        let inner = outer.open_with_atsam_root(recipient, root)?;
        self.ingest_opened(outer, inner, now_ms)
    }

    fn ingest_opened(
        &mut self,
        outer: RavenContactRequestV1,
        inner: ContactRequestInner,
        now_ms: u64,
    ) -> Result<ContactRequestInner, String> {
        if inner.request_id != outer.request_id {
            return Err("CONTACT_REQ_ID_MISMATCH".into());
        }
        if self
            .pending
            .iter()
            .any(|p| p.outer.request_id == outer.request_id)
        {
            return Ok(inner);
        }
        if self.pending.len() >= CONTACT_REQ_MAX_PENDING {
            return Err("CONTACT_REQ_INBOX_FULL".into());
        }
        let sender = outer.sender_pub;
        let from_sender: Vec<_> = self
            .pending
            .iter()
            .filter(|p| p.outer.sender_pub == sender)
            .collect();
        if from_sender.len() >= CONTACT_REQ_MAX_PER_SENDER {
            return Err("CONTACT_REQ_SENDER_CAP".into());
        }
        let in_window = from_sender
            .iter()
            .filter(|p| now_ms.saturating_sub(p.received_at) <= CONTACT_REQ_SENDER_WINDOW_MS)
            .count();
        if in_window >= CONTACT_REQ_MAX_PER_SENDER_WINDOW {
            return Err("CONTACT_REQ_RATE_LIMIT".into());
        }
        self.pending.push(PendingContactRequest {
            outer,
            inner: inner.clone(),
            received_at: now_ms,
        });
        Ok(inner)
    }

    fn take(&mut self, request_id: &[u8; 16]) -> Result<PendingContactRequest, String> {
        if let Some(i) = self
            .pending
            .iter()
            .position(|p| &p.outer.request_id == request_id)
        {
            Ok(self.pending.remove(i))
        } else {
            Err("CONTACT_REQ_NOT_FOUND".into())
        }
    }

    /// Accept → signed ContactAcceptV1 + local binding (raven_id + petname).
    pub fn accept(
        &mut self,
        request_id: &[u8; 16],
        accepter: &Identity,
        petname: &str,
        now_ms: u64,
    ) -> Result<ContactAcceptOutcome, String> {
        let pending = self.take(request_id)?;
        let pet = petname.trim();
        if pet.is_empty() {
            return Err("CONTACT_ACCEPT_PETNAME_REQUIRED".into());
        }
        let accept = ContactAcceptV1 {
            request_id: pending.outer.request_id,
            accepter_raven_id: String::new(),
            requester_raven_id: pending.inner.sender_raven_id.clone(),
            accepted_at: now_ms,
            signature: [0u8; 64],
            accepter_pub: [0u8; 32],
        }
        .sign(accepter)?;
        let binding = ContactBinding {
            raven_id: pending.inner.sender_raven_id,
            pub_hex: hex::encode(pending.outer.sender_pub),
            petname: pet.to_string(),
            verification_state: VerificationState::TrustedContact,
        };
        Ok(ContactAcceptOutcome { accept, binding })
    }

    pub fn decline(&mut self, request_id: &[u8; 16]) -> Result<(), String> {
        let _ = self.take(request_id)?;
        Ok(())
    }

    /// Local block — no central moderation. Removes pending + blocks sender pub.
    pub fn block(&mut self, request_id: &[u8; 16], blocks: &mut BlockList) -> Result<(), String> {
        let pending = self.take(request_id)?;
        blocks.block(&hex::encode(pending.outer.sender_pub));
        Ok(())
    }
}
