//! ML-KEM-768 + X25519 hybrid pairing toward ATSAM K_root.
//!
//! Spec: `protocol/ATSAM_PRIMITIVE_MAPPING_V1.md`
//! Uses RustCrypto `ml-kem` (FIPS 203). Shared secret feeds `atsam_root::derive_root`
//! together with X25519 ECDH — matching the iOS hybrid composition.
//!
//! RNG bridging: workspace `rand` 0.8 ≠ ml-kem's rand_core 0.10 `CryptoRng`, so we
//! draw bytes via `RngCore` and feed seed / deterministic encap (`hazmat`) APIs.
//!
//! Honest gap: Apple CryptoKit ML-KEM ciphertext bytes are not yet cross-checked
//! against these KATs in CI (OS-gated on iOS). Rust proves encap/decap agreement
//! and hybrid root derivation.

use ml_kem::kem::{Decapsulate, Key, KeyExport};
use ml_kem::{B32, DecapsulationKey, EncapsulationKey, MlKem768, Seed};
use rand_core::RngCore;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::atsam_root::{derive_root, x25519_shared};

/// ML-KEM-768 encapsulation key size (FIPS 203).
pub const EK_LEN: usize = 1184;
/// ML-KEM-768 ciphertext size.
pub const CT_LEN: usize = 1088;
/// Preferred private seed size for ML-KEM DK.
pub const DK_SEED_LEN: usize = 64;

pub struct HybridKeypair {
    pub x25519_secret: [u8; 32],
    pub x25519_public: [u8; 32],
    /// 64-byte ML-KEM seed (preferred private form).
    pub mlkem_seed: [u8; DK_SEED_LEN],
    pub mlkem_ek_bytes: Vec<u8>,
}

impl HybridKeypair {
    pub fn generate<R: RngCore + ?Sized>(rng: &mut R) -> Self {
        let mut x_seed = [0u8; 32];
        rng.fill_bytes(&mut x_seed);
        let sk = StaticSecret::from(x_seed);
        let x25519_public = PublicKey::from(&sk).to_bytes();
        let x25519_secret = sk.to_bytes();

        let mut seed_bytes = [0u8; DK_SEED_LEN];
        rng.fill_bytes(&mut seed_bytes);
        let seed = Seed::try_from(seed_bytes.as_slice()).expect("seed len");
        let dk = DecapsulationKey::<MlKem768>::from_seed(seed);
        let mlkem_seed = seed_bytes;
        let ek_encoded = dk.encapsulation_key().to_bytes();
        let mlkem_ek_bytes = ek_encoded.as_slice().to_vec();
        assert_eq!(mlkem_ek_bytes.len(), EK_LEN);
        Self {
            x25519_secret,
            x25519_public,
            mlkem_seed,
            mlkem_ek_bytes,
        }
    }
}

fn parse_ek(bytes: &[u8]) -> Result<EncapsulationKey<MlKem768>, String> {
    if bytes.len() != EK_LEN {
        return Err("mlkem ek length".into());
    }
    let key: Key<EncapsulationKey<MlKem768>> =
        bytes.try_into().map_err(|_| "ek array".to_string())?;
    EncapsulationKey::<MlKem768>::new(&key).map_err(|_| "ek decode".into())
}

/// Initiator: ECDH + ML-KEM.Encap(peer_ek) → (ct_pq, K_root).
pub fn initiate_hybrid_root<R: RngCore + ?Sized>(
    rng: &mut R,
    our_x_secret: &[u8; 32],
    peer_x_public: &[u8; 32],
    peer_mlkem_ek: &[u8],
    transcript_hash: &[u8; 32],
) -> Result<(Vec<u8>, [u8; 32]), String> {
    let z_x = x25519_shared(our_x_secret, peer_x_public);
    let ek = parse_ek(peer_mlkem_ek)?;
    let mut m = [0u8; 32];
    rng.fill_bytes(&mut m);
    let m_arr = B32::try_from(m.as_slice()).map_err(|_| "m")?;
    let (ct, ss) = ek.encapsulate_deterministic(&m_arr);
    let ct_bytes = ct.as_slice().to_vec();
    if ct_bytes.len() != CT_LEN {
        return Err("ct length".into());
    }
    let mut z_pq = [0u8; 32];
    z_pq.copy_from_slice(ss.as_slice());
    Ok((ct_bytes, derive_root(&z_x, &z_pq, transcript_hash)))
}

/// Responder: ECDH + ML-KEM.Decap(ct) → K_root.
pub fn respond_hybrid_root(
    our_x_secret: &[u8; 32],
    peer_x_public: &[u8; 32],
    our_mlkem_seed: &[u8; DK_SEED_LEN],
    ct_pq: &[u8],
    transcript_hash: &[u8; 32],
) -> Result<[u8; 32], String> {
    if ct_pq.len() != CT_LEN {
        return Err("mlkem ct length".into());
    }
    let z_x = x25519_shared(our_x_secret, peer_x_public);
    let seed = Seed::try_from(our_mlkem_seed.as_slice()).map_err(|_| "seed")?;
    let dk = DecapsulationKey::<MlKem768>::from_seed(seed);
    let ct = ct_pq.try_into().map_err(|_| "ct array")?;
    let ss = dk.decapsulate(&ct);
    let mut z_pq = [0u8; 32];
    z_pq.copy_from_slice(ss.as_slice());
    Ok(derive_root(&z_x, &z_pq, transcript_hash))
}

/// Deterministic encap for KATs (`hazmat` feature).
pub fn encapsulate_deterministic(
    peer_mlkem_ek: &[u8],
    m: &[u8; 32],
) -> Result<(Vec<u8>, [u8; 32]), String> {
    let ek = parse_ek(peer_mlkem_ek)?;
    let m_arr = B32::try_from(m.as_slice()).map_err(|_| "m")?;
    let (ct, ss) = ek.encapsulate_deterministic(&m_arr);
    let mut z = [0u8; 32];
    z.copy_from_slice(ss.as_slice());
    Ok((ct.as_slice().to_vec(), z))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atsam_root::transcript_hash;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    #[test]
    fn hybrid_agreement() {
        let mut rng = StdRng::seed_from_u64(42);
        let alice = HybridKeypair::generate(&mut rng);
        let bob = HybridKeypair::generate(&mut rng);
        let th = transcript_hash(b"hybrid-kat");
        let (ct, root_a) = initiate_hybrid_root(
            &mut rng,
            &alice.x25519_secret,
            &bob.x25519_public,
            &bob.mlkem_ek_bytes,
            &th,
        )
        .unwrap();
        let root_b = respond_hybrid_root(
            &bob.x25519_secret,
            &alice.x25519_public,
            &bob.mlkem_seed,
            &ct,
            &th,
        )
        .unwrap();
        assert_eq!(root_a, root_b);
        assert_eq!(ct.len(), CT_LEN);
        assert_eq!(bob.mlkem_ek_bytes.len(), EK_LEN);
    }
}
