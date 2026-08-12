//! RavenRoutingTagV1 — HMAC-SHA256(K_route, "rvn1/route" || epoch_be8 || counter_be8)[:16]

use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub const LABEL: &[u8] = b"rvn1/route";

pub fn derive(k_route: &[u8], epoch: u64, counter: u64) -> [u8; 16] {
    let mut mac = HmacSha256::new_from_slice(k_route).expect("HMAC key");
    mac.update(LABEL);
    mac.update(&epoch.to_be_bytes());
    mac.update(&counter.to_be_bytes());
    let full = mac.finalize().into_bytes();
    let mut out = [0u8; 16];
    out.copy_from_slice(&full[..16]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_zero_matches_vector() {
        let k: Vec<u8> = (0u8..32).collect();
        let tag = derive(&k, 1700000000, 0);
        assert_eq!(hex::encode(tag), "611432077911411fb5470eb80f1ff119");
    }
}
