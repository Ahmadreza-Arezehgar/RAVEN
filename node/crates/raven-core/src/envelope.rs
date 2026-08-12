//! RavenEnvelopeV1 — pack/unpack + signing bytes (mutable-field rule).

use sha2::{Digest, Sha256};

use crate::identity::Identity;

pub const MAGIC: &[u8; 4] = b"RVN1";
pub const VERSION: u8 = 1;
pub const PREFIX_LEN: usize = 86;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EnvType {
    Message = 1,
    Ack = 2,
    AliasGossip = 3,
    Capabilities = 4,
}

impl EnvType {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::Message),
            2 => Some(Self::Ack),
            3 => Some(Self::AliasGossip),
            4 => Some(Self::Capabilities),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Envelope {
    pub env_type: u8,
    pub flags: u16,
    pub message_id: [u8; 16],
    pub routing_tag: [u8; 16],
    pub dest_device_hint: u64,
    pub created_at: u64,
    pub expires_at: u64,
    pub hop_limit: u8,
    pub replication_budget: u8,
    pub anti_replay_nonce: [u8; 12],
    pub ratchet_header_ciphertext: Vec<u8>,
    pub message_ciphertext: Vec<u8>,
    pub sender_authentication: Vec<u8>,
}

impl Envelope {
    pub fn pack(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(
            PREFIX_LEN
                + self.ratchet_header_ciphertext.len()
                + self.message_ciphertext.len()
                + self.sender_authentication.len(),
        );
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        out.push(self.env_type);
        out.extend_from_slice(&self.flags.to_be_bytes());
        out.extend_from_slice(&self.message_id);
        out.extend_from_slice(&self.routing_tag);
        out.extend_from_slice(&self.dest_device_hint.to_be_bytes());
        out.extend_from_slice(&self.created_at.to_be_bytes());
        out.extend_from_slice(&self.expires_at.to_be_bytes());
        out.push(self.hop_limit);
        out.push(self.replication_budget);
        out.extend_from_slice(&self.anti_replay_nonce);
        out.extend_from_slice(&(self.ratchet_header_ciphertext.len() as u16).to_be_bytes());
        out.extend_from_slice(&(self.message_ciphertext.len() as u32).to_be_bytes());
        out.extend_from_slice(&(self.sender_authentication.len() as u16).to_be_bytes());
        out.extend_from_slice(&self.ratchet_header_ciphertext);
        out.extend_from_slice(&self.message_ciphertext);
        out.extend_from_slice(&self.sender_authentication);
        out
    }

    pub fn unpack(raw: &[u8]) -> Option<Self> {
        if raw.len() < PREFIX_LEN || &raw[0..4] != MAGIC || raw[4] != VERSION {
            return None;
        }
        let env_type = raw[5];
        let flags = u16::from_be_bytes([raw[6], raw[7]]);
        let mut message_id = [0u8; 16];
        message_id.copy_from_slice(&raw[8..24]);
        let mut routing_tag = [0u8; 16];
        routing_tag.copy_from_slice(&raw[24..40]);
        let dest_device_hint = u64::from_be_bytes(raw[40..48].try_into().ok()?);
        let created_at = u64::from_be_bytes(raw[48..56].try_into().ok()?);
        let expires_at = u64::from_be_bytes(raw[56..64].try_into().ok()?);
        let hop_limit = raw[64];
        let replication_budget = raw[65];
        let mut anti_replay_nonce = [0u8; 12];
        anti_replay_nonce.copy_from_slice(&raw[66..78]);
        let hdr_len = u16::from_be_bytes([raw[78], raw[79]]) as usize;
        let body_len = u32::from_be_bytes(raw[80..84].try_into().ok()?) as usize;
        let auth_len = u16::from_be_bytes([raw[84], raw[85]]) as usize;
        let mut o = PREFIX_LEN;
        if raw.len() != o + hdr_len + body_len + auth_len {
            return None;
        }
        let ratchet_header_ciphertext = raw[o..o + hdr_len].to_vec();
        o += hdr_len;
        let message_ciphertext = raw[o..o + body_len].to_vec();
        o += body_len;
        let sender_authentication = raw[o..o + auth_len].to_vec();
        Some(Self {
            env_type,
            flags,
            message_id,
            routing_tag,
            dest_device_hint,
            created_at,
            expires_at,
            hop_limit,
            replication_budget,
            anti_replay_nonce,
            ratchet_header_ciphertext,
            message_ciphertext,
            sender_authentication,
        })
    }

    /// Signing bytes: mutable fields zeroed, auth_len fixed to 64, ciphertext blobs by hash.
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut prefix = Vec::with_capacity(PREFIX_LEN);
        prefix.extend_from_slice(MAGIC);
        prefix.push(VERSION);
        prefix.push(self.env_type);
        prefix.extend_from_slice(&self.flags.to_be_bytes());
        prefix.extend_from_slice(&self.message_id);
        prefix.extend_from_slice(&self.routing_tag);
        prefix.extend_from_slice(&0u64.to_be_bytes()); // dest_device_hint
        prefix.extend_from_slice(&self.created_at.to_be_bytes());
        prefix.extend_from_slice(&self.expires_at.to_be_bytes());
        prefix.push(0); // hop_limit
        prefix.push(0); // replication_budget
        prefix.extend_from_slice(&self.anti_replay_nonce);
        prefix.extend_from_slice(&(self.ratchet_header_ciphertext.len() as u16).to_be_bytes());
        prefix.extend_from_slice(&(self.message_ciphertext.len() as u32).to_be_bytes());
        prefix.extend_from_slice(&64u16.to_be_bytes()); // canonical auth_len
        debug_assert_eq!(prefix.len(), PREFIX_LEN);

        let mut out = prefix;
        out.extend_from_slice(&Sha256::digest(&self.ratchet_header_ciphertext));
        out.extend_from_slice(&Sha256::digest(&self.message_ciphertext));
        out
    }

    pub fn sign_with(&mut self, identity: &Identity) {
        let sig = identity.sign(&self.signing_bytes());
        self.sender_authentication = sig.to_vec();
    }

    pub fn verify(&self, signer_ed_pub: &[u8; 32]) -> bool {
        if self.sender_authentication.len() != 64 {
            return false;
        }
        let mut sig = [0u8; 64];
        sig.copy_from_slice(&self.sender_authentication);
        Identity::verify(signer_ed_pub, &self.signing_bytes(), &sig)
    }
}
