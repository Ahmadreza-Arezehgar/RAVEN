//! Alias / device cert / capabilities signing bytes for rvn1 vector parity.

use crate::canon::{lp, u64_be};
use crate::identity::Identity;

pub fn alias_signing_bytes(
    alias: &str,
    identity_address: &str,
    sequence: u64,
    expires_at: u64,
) -> Result<Vec<u8>, String> {
    let mut out = b"rvn1/alias".to_vec();
    out.extend(lp(alias.as_bytes())?);
    out.extend(lp(identity_address.as_bytes())?);
    out.extend_from_slice(&u64_be(sequence));
    out.extend_from_slice(&u64_be(expires_at));
    Ok(out)
}

pub fn device_cert_signing_bytes(
    device_ed_pub: &[u8],
    device_x_pub: &[u8],
    device_id: &str,
    not_before: u64,
    not_after: u64,
    capabilities: u64,
) -> Result<Vec<u8>, String> {
    let mut out = b"rvn1/devcert".to_vec();
    out.extend(lp(device_ed_pub)?);
    out.extend(lp(device_x_pub)?);
    out.extend(lp(device_id.as_bytes())?);
    out.extend_from_slice(&u64_be(not_before));
    out.extend_from_slice(&u64_be(not_after));
    out.extend_from_slice(&u64_be(capabilities));
    Ok(out)
}

pub fn capabilities_signing_bytes(
    identity_address: &str,
    capability_bits: u64,
    expires_at: u64,
) -> Result<Vec<u8>, String> {
    let mut out = b"rvn1/caps".to_vec();
    out.extend(lp(identity_address.as_bytes())?);
    out.extend_from_slice(&u64_be(capability_bits));
    out.extend_from_slice(&u64_be(expires_at));
    Ok(out)
}

pub fn verify_sig(pub_key: &[u8; 32], msg: &[u8], sig: &[u8]) -> bool {
    if sig.len() != 64 {
        return false;
    }
    let mut s = [0u8; 64];
    s.copy_from_slice(sig);
    Identity::verify(pub_key, msg, &s)
}
