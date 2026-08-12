//! Bech32m (BIP-350) encode/decode for RavenAddressV1.
//! Uses the `bech32` crate's Bech32m variant — same checksum constant as
//! `protocol/reference/raven_protocol/bech32m.py`.

use bech32::{Bech32m, Hrp};

pub fn encode(hrp: &str, payload: &[u8]) -> Result<String, String> {
    let hrp = Hrp::parse(hrp).map_err(|e| e.to_string())?;
    bech32::encode::<Bech32m>(hrp, payload).map_err(|e| e.to_string())
}

pub fn decode(s: &str) -> Option<(String, Vec<u8>)> {
    let (hrp, data) = bech32::decode(s).ok()?;
    Some((hrp.to_string(), data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_bytes() {
        let payload = [0x01u8]
            .into_iter()
            .chain([0xABu8; 20])
            .collect::<Vec<_>>();
        let enc = encode("rvn", &payload).unwrap();
        assert!(enc.starts_with("rvn1"));
        let (hrp, data) = decode(&enc).unwrap();
        assert_eq!(hrp, "rvn");
        assert_eq!(data, payload);
    }
}
