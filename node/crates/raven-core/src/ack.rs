//! RavenAckV1 signing bytes (body record; carried inside envelope when env_type=2).

use crate::identity::Identity;

pub const STATUS_DELIVERED: u8 = 1;
pub const STATUS_READ: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ack {
    pub acked_message_id: [u8; 16],
    pub status: u8,
    pub ack_nonce: [u8; 12],
    pub created_at: u64,
}

impl Ack {
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + 16 + 1 + 12 + 8);
        out.extend_from_slice(b"rvn1/ack");
        out.extend_from_slice(&self.acked_message_id);
        out.push(self.status);
        out.extend_from_slice(&self.ack_nonce);
        out.extend_from_slice(&self.created_at.to_be_bytes());
        out
    }

    pub fn sign(&self, identity: &Identity) -> [u8; 64] {
        identity.sign(&self.signing_bytes())
    }

    pub fn verify(&self, sig: &[u8; 64], signer_ed_pub: &[u8; 32]) -> bool {
        Identity::verify(signer_ed_pub, &self.signing_bytes(), sig)
    }
}
