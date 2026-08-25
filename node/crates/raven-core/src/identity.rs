//! Ed25519 identity — never log or print private keys.

use crate::address::encode_address;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;

pub struct Identity {
    verifying: VerifyingKey,
    signing: SigningKey,
}

impl Identity {
    pub fn generate() -> Self {
        let signing = SigningKey::generate(&mut OsRng);
        let verifying = signing.verifying_key();
        Self { verifying, signing }
    }

    /// Load from 32-byte RFC-8032 seed (test vectors / persistence).
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        let signing = SigningKey::from_bytes(seed);
        let verifying = signing.verifying_key();
        Self { verifying, signing }
    }

    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.verifying.to_bytes()
    }

    pub fn address(&self) -> String {
        encode_address(&self.public_key_bytes())
    }

    pub fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.signing.sign(msg).to_bytes()
    }

    pub fn verify(pub_key: &[u8; 32], msg: &[u8], sig: &[u8; 64]) -> bool {
        let Ok(vk) = VerifyingKey::from_bytes(pub_key) else {
            return false;
        };
        let Ok(signature) = Signature::from_slice(sig) else {
            return false;
        };
        vk.verify(msg, &signature).is_ok()
    }

    /// Seed bytes for encrypted persistence only — callers MUST NOT print.
    pub fn seed_bytes(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }
}
