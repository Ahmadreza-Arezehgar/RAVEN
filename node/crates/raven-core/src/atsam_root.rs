//! ATSAM hybrid root derivation given known shared secrets (no ML-KEM eng).
//!
//! Matches iOS `ATSAMRootDerivation.deriveRoot`:
//!   K_root = HKDF(ikm=Z_X||Z_PQ, salt=transcript_hash,
//!                 info="ATSAM/v1/pair-init"||transcript_hash, L=32)
//!
//! Production ML-KEM encapsulation remains iOS-primary; Rust proves AEAD+ratchet
//! and root HKDF with shared vectors / X25519 ECDH + supplied Z_PQ.

use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

pub const PAIR_INIT: &[u8] = b"ATSAM/v1/pair-init";
pub const TRANSCRIPT_DOMAIN: &[u8] = b"ATSAM/v1/transcript";

/// SHA-256(domain || material) — matches ATSAMTranscript domain prepend.
pub fn transcript_hash(material: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(TRANSCRIPT_DOMAIN);
    h.update(material);
    h.finalize().into()
}

/// Derive K_root from 32-byte classical + 32-byte PQ shares + transcript hash.
pub fn derive_root(z_x: &[u8; 32], z_pq: &[u8; 32], transcript_hash: &[u8; 32]) -> [u8; 32] {
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(z_x);
    ikm[32..].copy_from_slice(z_pq);
    let mut info = Vec::with_capacity(PAIR_INIT.len() + 32);
    info.extend_from_slice(PAIR_INIT);
    info.extend_from_slice(transcript_hash);
    let hk = Hkdf::<Sha256>::new(Some(transcript_hash.as_slice()), &ikm);
    let mut okm = [0u8; 32];
    hk.expand(&info, &mut okm).expect("hkdf");
    ikm.zeroize();
    okm
}

/// X25519 ECDH → Z_X. Caller supplies Z_PQ (zeros for classical-only KAT).
pub fn x25519_shared(secret: &[u8; 32], peer_public: &[u8; 32]) -> [u8; 32] {
    let sk = StaticSecret::from(*secret);
    let pk = PublicKey::from(*peer_public);
    sk.diffie_hellman(&pk).to_bytes()
}

/// Production pairing variant: rejects non-contributory/low-order peer keys
/// instead of feeding an all-zero X25519 result into the hybrid root.
pub fn x25519_shared_checked(
    secret: &[u8; 32],
    peer_public: &[u8; 32],
) -> Result<[u8; 32], String> {
    let shared = x25519_shared(secret, peer_public);
    if shared.iter().all(|byte| *byte == 0) {
        return Err("X25519 non-contributory peer key".into());
    }
    Ok(shared)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_known_vector() {
        let z_x = [0x11u8; 32];
        let z_pq = [0x22u8; 32];
        let th = transcript_hash(b"kat-pair-material");
        assert_eq!(
            hex::encode(th),
            "46256683869ab07b5ea52f5d46628d027b04a400d8ee160366388e38606ffe46"
        );
        let root = derive_root(&z_x, &z_pq, &th);
        // Locked for shared-vector export — do not change without bumping vector id.
        assert_eq!(
            hex::encode(root),
            "67d6ad5db5b0e7012df9e9a7c7167cddb238b8c4bd0b4098a36cfbe7452ed8de"
        );
    }

    #[test]
    fn x25519_agreement() {
        let a = [0x01u8; 32];
        let b = [0x02u8; 32];
        // clamp-ish: x25519-dalek StaticSecret clamps internally
        let pa = PublicKey::from(&StaticSecret::from(a)).to_bytes();
        let pb = PublicKey::from(&StaticSecret::from(b)).to_bytes();
        let zab = x25519_shared(&a, &pb);
        let zba = x25519_shared(&b, &pa);
        assert_eq!(zab, zba);
    }

    #[test]
    fn non_contributory_x25519_key_is_rejected() {
        assert!(x25519_shared_checked(&[7u8; 32], &[0u8; 32]).is_err());
    }
}
