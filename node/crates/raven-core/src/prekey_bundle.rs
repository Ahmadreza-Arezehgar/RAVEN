//! RavenPrekeyBundleV1 — signed hybrid first-contact material.
//!
//! Spec: `protocol/RAVEN_PREKEY_BUNDLE_V1.md`

use crate::canon::{lp, u64_be};
use crate::identity::Identity;

pub const PREKEY_DOMAIN: &[u8] = b"rvn1/prekey";
pub const MLKEM768_EK_LEN: usize = 1184;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrekeyBundle {
    pub identity_ed25519_pub: [u8; 32],
    pub device_id: String,
    pub x25519_pub: [u8; 32],
    pub mlkem768_ek: Vec<u8>,
    pub signed_prekey_id: u32,
    pub one_time_prekey_id: u32,
    pub one_time_x25519_pub: Option<[u8; 32]>,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub signature: [u8; 64],
}

impl PrekeyBundle {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, String> {
        if self.mlkem768_ek.len() != MLKEM768_EK_LEN {
            return Err("mlkem ek length".into());
        }
        if self.one_time_prekey_id == 0 && self.one_time_x25519_pub.is_some() {
            return Err("otp inconsistency".into());
        }
        if self.one_time_prekey_id != 0 && self.one_time_x25519_pub.is_none() {
            return Err("otp missing key".into());
        }
        let mut out = PREKEY_DOMAIN.to_vec();
        out.push(1);
        out.extend_from_slice(&self.identity_ed25519_pub);
        out.extend(lp(self.device_id.as_bytes())?);
        out.extend_from_slice(&self.x25519_pub);
        out.extend_from_slice(&self.mlkem768_ek);
        out.extend_from_slice(&self.signed_prekey_id.to_be_bytes());
        out.extend_from_slice(&self.one_time_prekey_id.to_be_bytes());
        if let Some(otp) = self.one_time_x25519_pub {
            out.extend_from_slice(&otp);
        }
        out.extend_from_slice(&u64_be(self.created_at_ms));
        out.extend_from_slice(&u64_be(self.expires_at_ms));
        Ok(out)
    }

    pub fn sign(mut self, id: &Identity) -> Result<Self, String> {
        self.identity_ed25519_pub = id.public_key_bytes();
        let sb = self.signing_bytes()?;
        self.signature = id.sign(&sb);
        Ok(self)
    }

    pub fn verify(&self, now_ms: u64) -> Result<(), String> {
        if self.expires_at_ms <= self.created_at_ms {
            return Err("PREKEY_EXPIRED".into());
        }
        // ±5 min skew on expiry check.
        let skew = 5 * 60 * 1000u64;
        if now_ms.saturating_add(skew) < self.created_at_ms {
            return Err("PREKEY_NOT_YET_VALID".into());
        }
        if now_ms > self.expires_at_ms.saturating_add(skew) {
            return Err("PREKEY_EXPIRED".into());
        }
        if self.mlkem768_ek.iter().all(|&b| b == 0) {
            return Err("PREKEY_DEGRADED_EK".into());
        }
        let sb = self.signing_bytes()?;
        if !Identity::verify(&self.identity_ed25519_pub, &sb, &self.signature) {
            return Err("PREKEY_BAD_SIG".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo_bundle(id: &Identity) -> PrekeyBundle {
        PrekeyBundle {
            identity_ed25519_pub: id.public_key_bytes(),
            device_id: "dev1".into(),
            x25519_pub: [7u8; 32],
            mlkem768_ek: vec![3u8; MLKEM768_EK_LEN],
            signed_prekey_id: 1,
            one_time_prekey_id: 0,
            one_time_x25519_pub: None,
            created_at_ms: 1_000,
            expires_at_ms: 9_000_000_000_000,
            signature: [0u8; 64],
        }
    }

    #[test]
    fn sign_verify_ok() {
        let id = Identity::generate();
        let b = demo_bundle(&id).sign(&id).unwrap();
        b.verify(2_000).unwrap();
    }

    #[test]
    fn bad_sig_rejected() {
        let id = Identity::generate();
        let mut b = demo_bundle(&id).sign(&id).unwrap();
        b.signature[0] ^= 0xff;
        assert_eq!(b.verify(2_000).unwrap_err(), "PREKEY_BAD_SIG");
    }

    #[test]
    fn zero_ek_rejected() {
        let id = Identity::generate();
        let mut b = demo_bundle(&id);
        b.mlkem768_ek = vec![0u8; MLKEM768_EK_LEN];
        let b = b.sign(&id).unwrap();
        assert_eq!(b.verify(2_000).unwrap_err(), "PREKEY_DEGRADED_EK");
    }
}
