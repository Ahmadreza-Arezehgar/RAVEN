//! Signal PQCKA Authenticator + KDF_OK matching the pinned `spqr` tree
//! (`fd320484…`, `src/authenticator.rs` + `send_ct`/`send_ek` KDF_OK sites).
//!
//! Domains are byte-exact with the pin:
//! - `Signal_PQCKA_V1_MLKEM768:SCKA Key` || epoch_be
//! - `Signal_PQCKA_V1_MLKEM768:Authenticator Update` || epoch_be
//! - `Signal_PQCKA_V1_MLKEM768:ekheader` || epoch_be || hdr
//! - `Signal_PQCKA_V1_MLKEM768:ciphertext` || epoch_be || ct
//!
//! `Authenticator.Update` follows the pin (IKM = root‖update, salt = 32×0), not
//! the HTML sketch that swaps salt/IKM.

use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

type HmacSha256 = Hmac<Sha256>;

pub const PROTOCOL_INFO: &[u8] = b"Signal_PQCKA_V1_MLKEM768";
pub const INFO_SCKA_KEY: &[u8] = b"Signal_PQCKA_V1_MLKEM768:SCKA Key";
pub const INFO_AUTH_UPDATE: &[u8] = b"Signal_PQCKA_V1_MLKEM768:Authenticator Update";
pub const INFO_EKHEADER: &[u8] = b"Signal_PQCKA_V1_MLKEM768:ekheader";
pub const INFO_CIPHERTEXT: &[u8] = b"Signal_PQCKA_V1_MLKEM768:ciphertext";

const ZERO_SALT: [u8; 32] = [0u8; 32];

#[derive(Zeroize, ZeroizeOnDrop)]
pub struct AuthState {
    pub root_key: [u8; 32],
    pub mac_key: [u8; 32],
}

impl AuthState {
    /// `Authenticator.Init(epoch, key)`: zero state then `Update(epoch, key)`.
    pub fn init(epoch: u64, key: &[u8; 32]) -> Self {
        let mut state = Self {
            root_key: [0u8; 32],
            mac_key: [0u8; 32],
        };
        state.update(epoch, key);
        state
    }

    /// Pin: `HKDF(salt=0³², ikm=root‖key, info=…Authenticator Update‖epoch_be, L=64)`.
    pub fn update(&mut self, epoch: u64, update_key: impl AsRef<[u8]>) {
        let update_key = update_key.as_ref();
        let mut ikm = Zeroizing::new(Vec::with_capacity(32 + update_key.len()));
        ikm.extend_from_slice(&self.root_key);
        ikm.extend_from_slice(update_key);
        let mut okm = Zeroizing::new([0u8; 64]);
        hkdf_expand_into(&ZERO_SALT, &ikm, &auth_update_info(epoch), okm.as_mut());
        self.root_key.copy_from_slice(&okm[..32]);
        self.mac_key.copy_from_slice(&okm[32..64]);
    }

    pub fn mac_hdr(&self, epoch: u64, hdr: &[u8]) -> [u8; 32] {
        mac_labeled(&self.mac_key, INFO_EKHEADER, epoch, hdr)
    }

    pub fn mac_ct(&self, epoch: u64, ct: &[u8]) -> [u8; 32] {
        mac_labeled(&self.mac_key, INFO_CIPHERTEXT, epoch, ct)
    }

    pub fn verify_hdr(&self, epoch: u64, hdr: &[u8], expected_mac: &[u8]) -> bool {
        verify_labeled(&self.mac_key, INFO_EKHEADER, epoch, hdr, expected_mac)
    }

    pub fn verify_ct(&self, epoch: u64, ct: &[u8], expected_mac: &[u8]) -> bool {
        verify_labeled(&self.mac_key, INFO_CIPHERTEXT, epoch, ct, expected_mac)
    }
}

/// `KDF_OK(shared_secret, epoch)` → 32-byte epoch output key (zeroizing wrapper).
pub fn kdf_ok(shared_secret: &[u8], epoch: u64) -> Zeroizing<[u8; 32]> {
    let mut info = Vec::with_capacity(INFO_SCKA_KEY.len() + 8);
    info.extend_from_slice(INFO_SCKA_KEY);
    info.extend_from_slice(&epoch.to_be_bytes());
    let mut out = Zeroizing::new([0u8; 32]);
    hkdf_expand_into(&ZERO_SALT, shared_secret, &info, out.as_mut());
    out
}

fn auth_update_info(epoch: u64) -> Vec<u8> {
    let mut info = Vec::with_capacity(INFO_AUTH_UPDATE.len() + 8);
    info.extend_from_slice(INFO_AUTH_UPDATE);
    info.extend_from_slice(&epoch.to_be_bytes());
    info
}

fn hkdf_expand_into(salt: &[u8], ikm: &[u8], info: &[u8], okm: &mut [u8]) {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    hk.expand(info, okm)
        .expect("HKDF-SHA256 expand length is always valid here");
}

fn mac_labeled(mac_key: &[u8; 32], label: &[u8], epoch: u64, body: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(mac_key).expect("HMAC accepts 32-byte keys");
    mac.update(label);
    mac.update(&epoch.to_be_bytes());
    mac.update(body);
    mac.finalize().into_bytes().into()
}

fn verify_labeled(
    mac_key: &[u8; 32],
    label: &[u8],
    epoch: u64,
    body: &[u8],
    expected_mac: &[u8],
) -> bool {
    let mut mac = HmacSha256::new_from_slice(mac_key).expect("HMAC accepts 32-byte keys");
    mac.update(label);
    mac.update(&epoch.to_be_bytes());
    mac.update(body);
    mac.verify_slice(expected_mac).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex32(s: &str) -> [u8; 32] {
        let bytes = hex::decode(s).expect("hex");
        let mut out = [0u8; 32];
        out.copy_from_slice(&bytes);
        out
    }

    /// Frozen KATs from independent Python `hashlib`/`hmac` (reviewer + local cross-check).
    #[test]
    fn frozen_kdf_ok_kat() {
        let ss = [0xA5u8; 32];
        let expected = hex32("972f5ae4e94fd7506a872c3bc9741764629dcf4fef05d138dae7489f07123d7b");
        assert_eq!(*kdf_ok(&ss, 9), expected);
        assert_ne!(*kdf_ok(&ss, 9), *kdf_ok(&ss, 10));
    }

    #[test]
    fn frozen_auth_init_kat() {
        let key = [0x11u8; 32];
        let state = AuthState::init(1, &key);
        assert_eq!(
            state.root_key,
            hex32("2f179ff05522a6967efdfd38f84955b2e3594eee23199c11c33e5bd7f5a56046")
        );
        assert_eq!(
            state.mac_key,
            hex32("9437200f1c144f85cbd110895621e622cc6be705ee72934399121e8ce8708b9f")
        );
    }

    #[test]
    fn frozen_mac_hdr_and_ct_kats() {
        let auth = AuthState::init(1, &[0x44; 32]);
        let hdr = [0x55u8; 64];
        let ct = [0x66u8; 1088];
        assert_eq!(
            auth.mac_hdr(1, &hdr),
            hex32("e6e70fede67dd441db684e5d5d92e55385328842ce73ac905b9e2c9872a44276")
        );
        assert_eq!(
            auth.mac_ct(1, &ct),
            hex32("a8c73e6ff20d2047d171ffe66c2e12e0119ec5be1e2cac5ca00933a73fc40825")
        );
        assert!(auth.verify_hdr(1, &hdr, &auth.mac_hdr(1, &hdr)));
        assert!(auth.verify_ct(1, &ct, &auth.mac_ct(1, &ct)));
        assert!(!auth.verify_hdr(2, &hdr, &auth.mac_hdr(1, &hdr)));
        assert!(!auth.verify_ct(2, &ct, &auth.mac_ct(1, &ct)));
    }

    #[test]
    fn authenticator_update_advances_mac_key_with_output_key() {
        let mut auth = AuthState::init(1, &[0x22; 32]);
        let before = auth.mac_key;
        let output_key = kdf_ok(&[0x33; 32], 1);
        auth.update(1, &output_key);
        assert_ne!(auth.mac_key, before);
        assert_ne!(auth.root_key, [0u8; 32]);
    }
}
