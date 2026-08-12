//! RavenAddressV1 — Bech32m over `0x01 || SHA-256(ed_pub)[:20]`.

use sha2::{Digest, Sha256};

use crate::bech32m;

pub const ADDRESS_VERSION: u8 = 1;
pub const HRP: &str = "rvn";

pub fn encode_address(identity_ed_pub: &[u8; 32]) -> String {
    let hash = Sha256::digest(identity_ed_pub);
    let mut payload = Vec::with_capacity(21);
    payload.push(ADDRESS_VERSION);
    payload.extend_from_slice(&hash[..20]);
    bech32m::encode(HRP, &payload).expect("bech32m encode")
}

/// Returns `(addr_hash_20, version)` or `None`.
pub fn decode_address(addr: &str) -> Option<(Vec<u8>, u8)> {
    let (hrp, payload) = bech32m::decode(addr.trim())?;
    if hrp != HRP || payload.len() != 21 {
        return None;
    }
    Some((payload[1..].to_vec(), payload[0]))
}

pub fn to_display(addr: &str) -> String {
    let data = addr.split_once('1').map(|(_, d)| d).unwrap_or(addr);
    let upper = data.to_uppercase();
    let groups: Vec<&str> = upper
        .as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect();
    format!("rvn1:{}", groups.join("-"))
}

pub fn from_display(disp: &str) -> String {
    let body = disp
        .trim()
        .strip_prefix("rvn1:")
        .unwrap_or(disp)
        .replace('-', "")
        .to_lowercase();
    format!("rvn1{body}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex::FromHex;

    #[test]
    fn alice_address_matches_vector() {
        let pub_hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
        let ed: [u8; 32] = <[u8; 32]>::from_hex(pub_hex).unwrap();
        let addr = encode_address(&ed);
        assert_eq!(addr, "rvn1qysluvwl5922yctzd0u9gpr06gn3k7ldfvecule0");
        let disp = to_display(&addr);
        assert_eq!(
            disp,
            "rvn1:QYSL-UVWL-5922-YCTZ-D0U9-GPR0-6GN3-K7LD-FVEC-ULE0"
        );
        assert_eq!(from_display(&disp), addr);
    }
}
