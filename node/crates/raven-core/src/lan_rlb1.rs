//! RLB1 — LAN bundle offer (device cert + signed prekey).
//!
//! Replaces `ash lab import-peer-cert` / import-prekey on the direct LAN path.
//! The payload is JSON of already-signed public records; confidentiality comes
//! from the Noise XX session that carries the frame.

use crate::device_cert::DeviceCertificate;
use crate::prekey_bundle::{PrekeyBundle, PrekeyBundleJson};

pub const RLB1_MAGIC: &[u8; 4] = b"RLB1";
pub const RLB1_VERSION: u8 = 1;
pub const RLB1_KIND_OFFER: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LanBundle {
    pub cert: DeviceCertificate,
    pub prekey: PrekeyBundle,
}

pub fn encode_offer(bundle: &LanBundle) -> Result<Vec<u8>, String> {
    let cert = serde_json::to_vec(&bundle.cert).map_err(|e| format!("rlb1 cert: {e}"))?;
    let prekey =
        serde_json::to_vec(&bundle.prekey.to_json()).map_err(|e| format!("rlb1 prekey: {e}"))?;
    if cert.len() > 64 * 1024 || prekey.len() > 64 * 1024 {
        return Err("rlb1 offer too large".into());
    }
    let mut out = Vec::with_capacity(6 + 8 + cert.len() + prekey.len());
    out.extend_from_slice(RLB1_MAGIC);
    out.push(RLB1_VERSION);
    out.push(RLB1_KIND_OFFER);
    out.extend_from_slice(&(cert.len() as u32).to_be_bytes());
    out.extend_from_slice(&cert);
    out.extend_from_slice(&(prekey.len() as u32).to_be_bytes());
    out.extend_from_slice(&prekey);
    Ok(out)
}

pub fn decode_offer(bytes: &[u8]) -> Result<LanBundle, String> {
    if bytes.len() < 10 || bytes[..4] != *RLB1_MAGIC {
        return Err("rlb1 magic".into());
    }
    if bytes[4] != RLB1_VERSION {
        return Err("rlb1 version".into());
    }
    if bytes[5] != RLB1_KIND_OFFER {
        return Err("rlb1 kind".into());
    }
    let cert_len = u32::from_be_bytes(bytes[6..10].try_into().unwrap()) as usize;
    let cert_start: usize = 10;
    let cert_end = cert_start
        .checked_add(cert_len)
        .ok_or_else(|| "rlb1 cert overflow".to_string())?;
    if cert_end + 4 > bytes.len() {
        return Err("rlb1 cert truncated".into());
    }
    let prekey_len = u32::from_be_bytes(bytes[cert_end..cert_end + 4].try_into().unwrap()) as usize;
    let prekey_start = cert_end + 4;
    let prekey_end = prekey_start
        .checked_add(prekey_len)
        .ok_or_else(|| "rlb1 prekey overflow".to_string())?;
    if prekey_end != bytes.len() {
        return Err("rlb1 trailing bytes".into());
    }
    let cert: DeviceCertificate = serde_json::from_slice(&bytes[cert_start..cert_end])
        .map_err(|e| format!("rlb1 cert json: {e}"))?;
    let prekey_json: PrekeyBundleJson = serde_json::from_slice(&bytes[prekey_start..prekey_end])
        .map_err(|e| format!("rlb1 prekey json: {e}"))?;
    let prekey = PrekeyBundle::from_json(&prekey_json)?;
    let bundle = LanBundle { cert, prekey };
    // Structural bind only here — callers verify signatures/expiry with a clock.
    bundle.require_identity_bound()?;
    Ok(bundle)
}

impl LanBundle {
    /// Cert and prekey must name the same user identity and device_id.
    pub fn require_identity_bound(&self) -> Result<(), String> {
        if self.prekey.identity_ed25519_pub != self.cert.user_ed_pub {
            return Err("lan bundle prekey/cert identity mismatch".into());
        }
        if self.prekey.device_id != self.cert.device_id {
            return Err("lan bundle prekey/cert device_id mismatch".into());
        }
        Ok(())
    }

    pub fn verify_bound(&self, now_ms: u64) -> Result<(), String> {
        self.require_identity_bound()?;
        self.cert.verify(now_ms)?;
        self.prekey.verify(now_ms)?;
        Ok(())
    }
}

pub fn is_rlb1(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && bytes[..4] == *RLB1_MAGIC
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;
    use crate::prekey_bundle::PrekeyBundle;

    #[test]
    fn offer_roundtrip() {
        let user = Identity::from_seed(&[0x51; 32]);
        let now = 1_700_000_000_000u64;
        let cert = crate::device_cert::DeviceCertificate::issue(
            &user,
            user.public_key_bytes(),
            [0x61; 32],
            "ash-primary",
            now - 60_000,
            now + 86_400_000,
            0,
        )
        .unwrap();
        let bundle = PrekeyBundle::from_hybrid_public(
            "ash-primary",
            [0x61; 32],
            vec![0x02; crate::prekey_bundle::MLKEM768_EK_LEN],
            1,
            now,
            now + 86_400_000,
        )
        .unwrap()
        .sign(&user)
        .unwrap();
        let offer = LanBundle {
            cert,
            prekey: bundle,
        };
        let wire = encode_offer(&offer).unwrap();
        assert!(is_rlb1(&wire));
        let back = decode_offer(&wire).unwrap();
        assert_eq!(back.cert, offer.cert);
        assert_eq!(back.prekey, offer.prekey);
    }
}
