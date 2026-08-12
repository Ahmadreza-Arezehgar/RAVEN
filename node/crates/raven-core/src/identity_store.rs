//! Secure persistence for the 32-byte Ed25519 identity seed.
//!
//! Platform backends (never log or print seed bytes):
//! - macOS: Keychain (generic password)
//! - Windows: DPAPI-protected `identity.seed` file
//! - Linux: Secret Service when available (glibc); else locked file mode `0600`
//!
//! Legacy plaintext `identity.seed` (exactly 32 raw bytes) is migrated on first load.

use std::path::{Path, PathBuf};

use zeroize::Zeroize;

use crate::identity::Identity;

/// Legacy / locked-file / DPAPI blob path under `data_dir`.
pub const SEED_FILE_NAME: &str = "identity.seed";

/// Non-secret marker naming the active backend.
pub const BACKEND_MARKER_NAME: &str = "identity.backend";

const DPAPI_MAGIC: &[u8] = b"RVNDPAPI";
#[cfg_attr(not(windows), allow(dead_code))]
const DPAPI_VERSION: u8 = 1;

#[cfg_attr(
    not(any(target_os = "macos", all(target_os = "linux", target_env = "gnu"))),
    allow(dead_code)
)]
const KEYCHAIN_SERVICE: &str = "app.raven.node.identity";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityStoreBackend {
    MacosKeychain,
    WindowsDpapiFile,
    LinuxSecretService,
    LockedFile,
}

impl IdentityStoreBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MacosKeychain => "macos-keychain",
            Self::WindowsDpapiFile => "windows-dpapi-file",
            Self::LinuxSecretService => "linux-secret-service",
            Self::LockedFile => "locked-file",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim() {
            "macos-keychain" => Some(Self::MacosKeychain),
            "windows-dpapi-file" => Some(Self::WindowsDpapiFile),
            "linux-secret-service" => Some(Self::LinuxSecretService),
            "locked-file" => Some(Self::LockedFile),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityStoreStatus {
    pub backend: Option<IdentityStoreBackend>,
    pub has_identity: bool,
    /// True when a legacy plaintext seed file still sits on disk (should be rare after load).
    pub legacy_plaintext_present: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum IdentityStoreError {
    #[error("identity store I/O: {0}")]
    Io(String),
    #[error("identity seed corrupt or wrong length")]
    Corrupt,
    #[error("secure store unavailable: {0}")]
    SecureStore(String),
}

impl IdentityStoreError {
    /// Errors must never embed seed material.
    pub fn redacted_display(&self) -> String {
        self.to_string()
    }
}

fn seed_path(data_dir: &Path) -> PathBuf {
    data_dir.join(SEED_FILE_NAME)
}

fn marker_path(data_dir: &Path) -> PathBuf {
    data_dir.join(BACKEND_MARKER_NAME)
}

fn account_for_data_dir(data_dir: &Path) -> String {
    use sha2::{Digest, Sha256};
    let canon = std::fs::canonicalize(data_dir).unwrap_or_else(|_| data_dir.to_path_buf());
    let mut h = Sha256::new();
    h.update(b"raven/identity-store/v1/");
    h.update(canon.to_string_lossy().as_bytes());
    hex::encode(h.finalize())
}

fn write_marker(data_dir: &Path, backend: IdentityStoreBackend) -> Result<(), IdentityStoreError> {
    std::fs::create_dir_all(data_dir).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    std::fs::write(marker_path(data_dir), format!("{}\n", backend.as_str()))
        .map_err(|e| IdentityStoreError::Io(e.to_string()))
}

fn read_marker(data_dir: &Path) -> Option<IdentityStoreBackend> {
    let raw = std::fs::read_to_string(marker_path(data_dir)).ok()?;
    IdentityStoreBackend::parse(raw.lines().next().unwrap_or(""))
}

#[cfg_attr(not(windows), allow(dead_code))]
fn is_dpapi_blob(bytes: &[u8]) -> bool {
    bytes.len() > DPAPI_MAGIC.len() + 1 && bytes.starts_with(DPAPI_MAGIC)
}

fn is_legacy_plaintext(bytes: &[u8]) -> bool {
    bytes.len() == 32 && !bytes.starts_with(DPAPI_MAGIC)
}

#[cfg_attr(
    not(any(target_os = "macos", all(target_os = "linux", target_env = "gnu"))),
    allow(dead_code)
)]
fn wipe_seed_file(path: &Path) -> Result<(), IdentityStoreError> {
    if path.exists() {
        let zeros = [0u8; 64];
        let _ = std::fs::write(path, &zeros[..32]);
        std::fs::remove_file(path).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    }
    Ok(())
}

#[cfg(unix)]
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn write_locked_seed_file(path: &Path, seed: &[u8; 32]) -> Result<(), IdentityStoreError> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    }
    if path.exists() {
        std::fs::remove_file(path).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    f.write_all(seed)
        .map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    Ok(())
}

#[cfg(not(unix))]
fn write_locked_seed_file(path: &Path, seed: &[u8; 32]) -> Result<(), IdentityStoreError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    }
    std::fs::write(path, seed).map_err(|e| IdentityStoreError::Io(e.to_string()))
}

fn read_raw_seed_file(path: &Path) -> Result<Option<Vec<u8>>, IdentityStoreError> {
    if !path.exists() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    Ok(Some(bytes))
}

// --- macOS Keychain ---------------------------------------------------------

#[cfg(target_os = "macos")]
fn keychain_set(account: &str, seed: &[u8; 32]) -> Result<(), IdentityStoreError> {
    use security_framework::passwords::{delete_generic_password, set_generic_password};
    let _ = delete_generic_password(KEYCHAIN_SERVICE, account);
    set_generic_password(KEYCHAIN_SERVICE, account, seed)
        .map_err(|e| IdentityStoreError::SecureStore(format!("keychain set: {e}")))
}

#[cfg(target_os = "macos")]
fn keychain_get(account: &str) -> Result<Option<[u8; 32]>, IdentityStoreError> {
    use security_framework::passwords::get_generic_password;
    match get_generic_password(KEYCHAIN_SERVICE, account) {
        Ok(bytes) => {
            if bytes.len() != 32 {
                return Err(IdentityStoreError::Corrupt);
            }
            let mut seed = [0u8; 32];
            seed.copy_from_slice(&bytes);
            Ok(Some(seed))
        }
        Err(_) => Ok(None),
    }
}

#[cfg(target_os = "macos")]
fn keychain_delete(account: &str) {
    use security_framework::passwords::delete_generic_password;
    let _ = delete_generic_password(KEYCHAIN_SERVICE, account);
}

// --- Windows DPAPI ----------------------------------------------------------

#[cfg(windows)]
fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, IdentityStoreError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let mut data_in = CRYPT_INTEGER_BLOB {
        cbData: plaintext.len() as u32,
        pbData: plaintext.as_ptr() as *mut u8,
    };
    let mut data_out = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut data_in,
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut data_out,
        )
    };
    if ok == 0 || data_out.pbData.is_null() || data_out.cbData == 0 {
        return Err(IdentityStoreError::SecureStore(
            "CryptProtectData failed".into(),
        ));
    }
    let slice =
        unsafe { std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize) };
    let out = slice.to_vec();
    unsafe {
        LocalFree(data_out.pbData as _);
    }
    Ok(out)
}

#[cfg(windows)]
fn dpapi_unprotect(blob: &[u8]) -> Result<Vec<u8>, IdentityStoreError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let mut data_in = CRYPT_INTEGER_BLOB {
        cbData: blob.len() as u32,
        pbData: blob.as_ptr() as *mut u8,
    };
    let mut data_out = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut data_in,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut data_out,
        )
    };
    if ok == 0 || data_out.pbData.is_null() || data_out.cbData == 0 {
        return Err(IdentityStoreError::SecureStore(
            "CryptUnprotectData failed".into(),
        ));
    }
    let slice =
        unsafe { std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize) };
    let out = slice.to_vec();
    unsafe {
        LocalFree(data_out.pbData as _);
    }
    Ok(out)
}

#[cfg(windows)]
fn write_dpapi_seed_file(path: &Path, seed: &[u8; 32]) -> Result<(), IdentityStoreError> {
    let protected = dpapi_protect(seed)?;
    let mut out = Vec::with_capacity(DPAPI_MAGIC.len() + 1 + protected.len());
    out.extend_from_slice(DPAPI_MAGIC);
    out.push(DPAPI_VERSION);
    out.extend_from_slice(&protected);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    }
    std::fs::write(path, &out).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    Ok(())
}

#[cfg(windows)]
fn load_dpapi_seed_file(path: &Path) -> Result<Option<[u8; 32]>, IdentityStoreError> {
    let Some(bytes) = read_raw_seed_file(path)? else {
        return Ok(None);
    };
    if !is_dpapi_blob(&bytes) {
        return Ok(None);
    }
    if bytes[DPAPI_MAGIC.len()] != DPAPI_VERSION {
        return Err(IdentityStoreError::Corrupt);
    }
    let plain = dpapi_unprotect(&bytes[DPAPI_MAGIC.len() + 1..])?;
    if plain.len() != 32 {
        return Err(IdentityStoreError::Corrupt);
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&plain);
    Ok(Some(seed))
}

// --- Linux Secret Service (glibc / desktop session) -------------------------

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn secret_service_set(account: &str, seed: &[u8; 32]) -> Result<(), IdentityStoreError> {
    use secret_service::{EncryptionType, SecretService};
    let ss = SecretService::new(EncryptionType::Dh)
        .map_err(|e| IdentityStoreError::SecureStore(format!("secret-service connect: {e}")))?;
    let collection = ss
        .get_default_collection()
        .map_err(|e| IdentityStoreError::SecureStore(format!("secret-service collection: {e}")))?;
    if collection.is_locked() {
        collection
            .unlock()
            .map_err(|e| IdentityStoreError::SecureStore(format!("secret-service unlock: {e}")))?;
    }
    if let Ok(items) =
        collection.search_items(vec![("service", KEYCHAIN_SERVICE), ("account", account)])
    {
        for item in items {
            let _ = item.delete();
        }
    }
    collection
        .create_item(
            "RAVEN node identity seed",
            vec![("service", KEYCHAIN_SERVICE), ("account", account)],
            seed,
            true,
            "text/plain",
        )
        .map_err(|e| IdentityStoreError::SecureStore(format!("secret-service create: {e}")))?;
    Ok(())
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn secret_service_get(account: &str) -> Result<Option<[u8; 32]>, IdentityStoreError> {
    use secret_service::{EncryptionType, SecretService};
    let Ok(ss) = SecretService::new(EncryptionType::Dh) else {
        return Ok(None);
    };
    let Ok(collection) = ss.get_default_collection() else {
        return Ok(None);
    };
    if collection.is_locked() {
        let _ = collection.unlock();
    }
    let Ok(items) =
        collection.search_items(vec![("service", KEYCHAIN_SERVICE), ("account", account)])
    else {
        return Ok(None);
    };
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    let secret = item
        .get_secret()
        .map_err(|e| IdentityStoreError::SecureStore(format!("secret-service get: {e}")))?;
    if secret.len() != 32 {
        return Err(IdentityStoreError::Corrupt);
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&secret);
    Ok(Some(seed))
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn secret_service_delete(account: &str) {
    use secret_service::{EncryptionType, SecretService};
    let Ok(ss) = SecretService::new(EncryptionType::Dh) else {
        return;
    };
    let Ok(collection) = ss.get_default_collection() else {
        return;
    };
    if let Ok(items) =
        collection.search_items(vec![("service", KEYCHAIN_SERVICE), ("account", account)])
    {
        for item in items {
            let _ = item.delete();
        }
    }
}

/// Persist seed using the best available platform backend.
fn store_seed(data_dir: &Path, seed: &[u8; 32]) -> Result<IdentityStoreBackend, IdentityStoreError> {
    std::fs::create_dir_all(data_dir).map_err(|e| IdentityStoreError::Io(e.to_string()))?;
    let path = seed_path(data_dir);
    let account = account_for_data_dir(data_dir);

    #[cfg(target_os = "macos")]
    {
        keychain_set(&account, seed)?;
        wipe_seed_file(&path)?;
        write_marker(data_dir, IdentityStoreBackend::MacosKeychain)?;
        return Ok(IdentityStoreBackend::MacosKeychain);
    }

    #[cfg(windows)]
    {
        write_dpapi_seed_file(&path, seed)?;
        write_marker(data_dir, IdentityStoreBackend::WindowsDpapiFile)?;
        return Ok(IdentityStoreBackend::WindowsDpapiFile);
    }

    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        if secret_service_set(&account, seed).is_ok() {
            wipe_seed_file(&path)?;
            write_marker(data_dir, IdentityStoreBackend::LinuxSecretService)?;
            return Ok(IdentityStoreBackend::LinuxSecretService);
        }
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let _ = account;
        write_locked_seed_file(&path, seed)?;
        write_marker(data_dir, IdentityStoreBackend::LockedFile)?;
        return Ok(IdentityStoreBackend::LockedFile);
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, account, seed);
        Err(IdentityStoreError::SecureStore(
            "unsupported platform for identity store".into(),
        ))
    }
}

fn bytes_to_seed(bytes: &[u8]) -> Result<[u8; 32], IdentityStoreError> {
    if bytes.len() != 32 {
        return Err(IdentityStoreError::Corrupt);
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(bytes);
    Ok(seed)
}

/// Load from platform store or locked file; migrate legacy plaintext when needed.
fn load_seed_with_migrate(
    data_dir: &Path,
) -> Result<Option<([u8; 32], IdentityStoreBackend)>, IdentityStoreError> {
    let path = seed_path(data_dir);
    let account = account_for_data_dir(data_dir);

    #[cfg(target_os = "macos")]
    {
        if let Some(seed) = keychain_get(&account)? {
            return Ok(Some((seed, IdentityStoreBackend::MacosKeychain)));
        }
        // Legacy plaintext file → Keychain.
        if let Some(bytes) = read_raw_seed_file(&path)? {
            if is_legacy_plaintext(&bytes) {
                let seed = bytes_to_seed(&bytes)?;
                let backend = store_seed(data_dir, &seed)?;
                return Ok(Some((seed, backend)));
            }
            return Err(IdentityStoreError::Corrupt);
        }
        return Ok(None);
    }

    #[cfg(windows)]
    {
        if let Some(seed) = load_dpapi_seed_file(&path)? {
            return Ok(Some((seed, IdentityStoreBackend::WindowsDpapiFile)));
        }
        if let Some(bytes) = read_raw_seed_file(&path)? {
            if is_legacy_plaintext(&bytes) {
                let seed = bytes_to_seed(&bytes)?;
                let backend = store_seed(data_dir, &seed)?;
                return Ok(Some((seed, backend)));
            }
            return Err(IdentityStoreError::Corrupt);
        }
        return Ok(None);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        {
            if let Some(seed) = secret_service_get(&account)? {
                return Ok(Some((seed, IdentityStoreBackend::LinuxSecretService)));
            }
        }

        if let Some(bytes) = read_raw_seed_file(&path)? {
            if !is_legacy_plaintext(&bytes) {
                return Err(IdentityStoreError::Corrupt);
            }
            let seed = bytes_to_seed(&bytes)?;
            // Promote locked/plaintext file into Secret Service when available.
            #[cfg(all(target_os = "linux", target_env = "gnu"))]
            {
                if secret_service_set(&account, &seed).is_ok() {
                    wipe_seed_file(&path)?;
                    write_marker(data_dir, IdentityStoreBackend::LinuxSecretService)?;
                    return Ok(Some((seed, IdentityStoreBackend::LinuxSecretService)));
                }
            }
            // Approved locked-file backend (mode should already be 0600; enforce on rewrite).
            if read_marker(data_dir) != Some(IdentityStoreBackend::LockedFile) {
                write_locked_seed_file(&path, &seed)?;
                write_marker(data_dir, IdentityStoreBackend::LockedFile)?;
            }
            return Ok(Some((seed, IdentityStoreBackend::LockedFile)));
        }
        let _ = account;
        return Ok(None);
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, account);
        Ok(None)
    }
}

/// Load identity if present (migrating legacy plaintext seed files).
pub fn load_identity(data_dir: &Path) -> Result<Option<Identity>, IdentityStoreError> {
    match load_seed_with_migrate(data_dir)? {
        Some((mut seed, _)) => {
            let id = Identity::from_seed(&seed);
            seed.zeroize();
            Ok(Some(id))
        }
        None => Ok(None),
    }
}

/// Load existing identity or generate + securely persist a new one.
pub fn load_or_create_identity(
    data_dir: &Path,
) -> Result<(Identity, IdentityStoreBackend), IdentityStoreError> {
    if let Some((mut seed, backend)) = load_seed_with_migrate(data_dir)? {
        let id = Identity::from_seed(&seed);
        seed.zeroize();
        return Ok((id, backend));
    }
    let id = Identity::generate();
    let mut seed = id.seed_bytes();
    let backend = store_seed(data_dir, &seed)?;
    seed.zeroize();
    Ok((id, backend))
}

/// Require an existing identity (no create).
pub fn load_identity_required(data_dir: &Path) -> Result<Identity, IdentityStoreError> {
    load_identity(data_dir)?.ok_or_else(|| {
        IdentityStoreError::Io("identity missing — run init / ash init first".into())
    })
}

/// Non-secret status for `ash doctor` and operators.
pub fn store_status(data_dir: &Path) -> IdentityStoreStatus {
    let path = seed_path(data_dir);
    #[allow(unused_variables)]
    let file_bytes = std::fs::read(&path).ok();
    // Prefer marker; fall back to probing stores without creating.
    let mut backend = read_marker(data_dir);
    if backend.is_none() {
        #[cfg(target_os = "macos")]
        {
            let account = account_for_data_dir(data_dir);
            if keychain_get(&account).ok().flatten().is_some() {
                backend = Some(IdentityStoreBackend::MacosKeychain);
            }
        }
        #[cfg(windows)]
        {
            if file_bytes.as_ref().map(|b| is_dpapi_blob(b)).unwrap_or(false) {
                backend = Some(IdentityStoreBackend::WindowsDpapiFile);
            }
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            if file_bytes
                .as_ref()
                .map(|b| is_legacy_plaintext(b))
                .unwrap_or(false)
            {
                backend = Some(IdentityStoreBackend::LockedFile);
            }
        }
    }
    let has_identity = match load_identity(data_dir) {
        Ok(Some(_)) => true,
        _ => false,
    };
    // After a successful load/migrate, plaintext should be gone on macOS / DPAPI hosts.
    let legacy_after = std::fs::read(&path)
        .ok()
        .map(|b| is_legacy_plaintext(&b))
        .unwrap_or(false);
    IdentityStoreStatus {
        backend,
        has_identity,
        legacy_plaintext_present: legacy_after
            && !matches!(
                backend,
                Some(IdentityStoreBackend::LockedFile)
            ),
    }
}

/// Test helper: remove platform credentials for this data_dir (best-effort).
pub fn test_cleanup(data_dir: &Path) {
    let account = account_for_data_dir(data_dir);
    #[cfg(target_os = "macos")]
    keychain_delete(&account);
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    secret_service_delete(&account);
    let _ = account;
    let _ = std::fs::remove_file(seed_path(data_dir));
    let _ = std::fs::remove_file(marker_path(data_dir));
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn create_load_round_trip() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        let (id, backend) = load_or_create_identity(dir).expect("create");
        assert!(matches!(
            backend,
            IdentityStoreBackend::MacosKeychain
                | IdentityStoreBackend::WindowsDpapiFile
                | IdentityStoreBackend::LinuxSecretService
                | IdentityStoreBackend::LockedFile
        ));
        let loaded = load_identity(dir).unwrap().expect("loaded");
        assert_eq!(id.public_key_bytes(), loaded.public_key_bytes());
        assert_eq!(id.address(), loaded.address());
        let (again, _) = load_or_create_identity(dir).unwrap();
        assert_eq!(again.public_key_bytes(), id.public_key_bytes());
        test_cleanup(dir);
    }

    #[test]
    fn migrates_legacy_plaintext_seed_file() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        std::fs::create_dir_all(dir).unwrap();
        let original = Identity::generate();
        let seed = original.seed_bytes();
        let path = seed_path(dir);
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)
                .unwrap();
            f.write_all(&seed).unwrap();
        }
        #[cfg(not(unix))]
        {
            std::fs::write(&path, &seed).unwrap();
        }

        let loaded = load_identity(dir).unwrap().expect("migrate+load");
        assert_eq!(loaded.public_key_bytes(), original.public_key_bytes());

        #[cfg(target_os = "macos")]
        {
            assert!(
                !path.exists(),
                "plaintext identity.seed must be removed after Keychain migrate"
            );
            assert_eq!(
                read_marker(dir),
                Some(IdentityStoreBackend::MacosKeychain)
            );
        }

        #[cfg(windows)]
        {
            let bytes = std::fs::read(&path).unwrap();
            assert!(
                is_dpapi_blob(&bytes),
                "Windows migrate must rewrite as DPAPI blob"
            );
            assert!(!is_legacy_plaintext(&bytes));
        }

        #[cfg(all(unix, not(target_os = "macos")))]
        {
            if path.exists() {
                let meta = std::fs::metadata(&path).unwrap();
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(meta.permissions().mode() & 0o777, 0o600);
            }
        }

        test_cleanup(dir);
    }

    #[test]
    fn error_display_never_embeds_seed_hex() {
        let seed = [0xabu8; 32];
        let hex = hex::encode(seed);
        let err = IdentityStoreError::SecureStore("keychain locked".into());
        let s = err.redacted_display();
        assert!(!s.contains(&hex));
        assert!(!s.contains("private"));
    }

    #[test]
    fn store_status_reports_backend_without_secrets() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        let _ = load_or_create_identity(dir).unwrap();
        let st = store_status(dir);
        assert!(st.has_identity);
        assert!(st.backend.is_some());
        let label = st.backend.unwrap().as_str();
        assert!(!label.is_empty());
        assert!(!label.contains("seed"));
        test_cleanup(dir);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn locked_file_permissions_are_0600_when_used() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        let id = Identity::generate();
        let seed = id.seed_bytes();
        write_locked_seed_file(&seed_path(dir), &seed).unwrap();
        write_marker(dir, IdentityStoreBackend::LockedFile).unwrap();
        let meta = std::fs::metadata(seed_path(dir)).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        let loaded = load_identity(dir).unwrap().unwrap();
        assert_eq!(loaded.public_key_bytes(), id.public_key_bytes());
        test_cleanup(dir);
    }
}
