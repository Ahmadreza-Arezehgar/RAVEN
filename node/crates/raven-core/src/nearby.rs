//! Nearby BLE ephemeral discovery — no permanent Raven ID in advertisements.

use rand::RngCore;
use sha2::{Digest, Sha256};

/// Ephemeral nearby advertisement (V1 mock / software substitute for GATT).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyAdvertisement {
    /// Rotating ephemeral token — NOT a Raven ID.
    pub ephemeral_token: [u8; 16],
    pub session_commitment: [u8; 32],
    pub issued_at_ms: u64,
    pub ttl_ms: u64,
}

impl NearbyAdvertisement {
    pub fn mint(now_ms: u64, ttl_ms: u64, confirm_secret: &[u8]) -> Self {
        let mut ephemeral_token = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut ephemeral_token);
        let mut h = Sha256::new();
        h.update(b"raven/nearby/v1");
        h.update(&ephemeral_token);
        h.update(confirm_secret);
        let session_commitment = h.finalize().into();
        Self {
            ephemeral_token,
            session_commitment,
            issued_at_ms: now_ms,
            ttl_ms,
        }
    }

    pub fn is_live(&self, now_ms: u64) -> bool {
        now_ms <= self.issued_at_ms.saturating_add(self.ttl_ms)
    }

    /// Advertisement bytes MUST NOT embed a permanent `rvn1` address.
    pub fn advertise_bytes(&self) -> Vec<u8> {
        let mut out = b"rvn1/nearby-adv".to_vec();
        out.extend_from_slice(&self.ephemeral_token);
        out.extend_from_slice(&self.session_commitment);
        out.extend_from_slice(&self.issued_at_ms.to_be_bytes());
        out.extend_from_slice(&self.ttl_ms.to_be_bytes());
        out
    }

    pub fn contains_permanent_raven_id(&self) -> bool {
        let bytes = self.advertise_bytes();
        let prefix = b"rvn1/nearby-adv";
        if bytes.len() <= prefix.len() {
            return false;
        }
        // Domain prefix uses "rvn1/" — check remainder for a bech32 Raven address.
        let rest = &bytes[prefix.len()..];
        String::from_utf8_lossy(rest).contains("rvn1")
    }
}

/// After mutual confirm, bind ephemeral session → Raven ID locally (not in adv).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyConfirmBinding {
    pub ephemeral_token: [u8; 16],
    pub peer_raven_id: String,
    pub peer_pub: [u8; 32],
    pub confirmed_at_ms: u64,
}

#[derive(Default)]
pub struct NearbyRegistry {
    pub live_ads: Vec<NearbyAdvertisement>,
    pub confirmed: Vec<NearbyConfirmBinding>,
}

impl NearbyRegistry {
    pub fn publish_ephemeral(&mut self, adv: NearbyAdvertisement) -> Result<(), String> {
        if adv.contains_permanent_raven_id() {
            return Err("NEARBY_PERMANENT_ID_IN_ADV".into());
        }
        self.live_ads.push(adv);
        Ok(())
    }

    pub fn scan_live(&self, now_ms: u64) -> Vec<&NearbyAdvertisement> {
        self.live_ads.iter().filter(|a| a.is_live(now_ms)).collect()
    }

    pub fn confirm(
        &mut self,
        token: [u8; 16],
        peer_raven_id: String,
        peer_pub: [u8; 32],
        now_ms: u64,
    ) {
        self.confirmed.push(NearbyConfirmBinding {
            ephemeral_token: token,
            peer_raven_id,
            peer_pub,
            confirmed_at_ms: now_ms,
        });
    }
}
