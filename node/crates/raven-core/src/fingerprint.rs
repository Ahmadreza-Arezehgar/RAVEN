//! RavenDeviceFingerprintV1 + deprecated MeshV1 hex.

use base64::Engine;
use sha2::{Digest, Sha256};

fn group4(s: &str) -> String {
    s.as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join("-")
}

/// Canonical app fingerprint (human safety number — not a routing key).
pub fn device_fingerprint_v1(ed_pub: &[u8; 32]) -> String {
    let h = Sha256::digest(ed_pub);
    let b64 = base64::engine::general_purpose::STANDARD.encode(&h[..9]);
    let stripped: String = b64.chars().filter(|c| *c != '+' && *c != '/').collect();
    let take = stripped.chars().take(12).collect::<String>();
    group4(&take)
}

/// Deprecated MeshV1 scheme — locked only for legacy vector migration checks.
pub fn mesh_v1_hex_fingerprint(ed_pub: &[u8; 32]) -> String {
    let h = Sha256::digest(ed_pub);
    group4(&hex::encode_upper(&h[..6]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex::FromHex;

    #[test]
    fn alice_fingerprint() {
        let ed: [u8; 32] = <[u8; 32]>::from_hex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        )
        .unwrap();
        assert_eq!(device_fingerprint_v1(&ed), "If4x-36FU-omFi");
        assert_eq!(mesh_v1_hex_fingerprint(&ed), "21FE-31DF-A154");
    }
}
