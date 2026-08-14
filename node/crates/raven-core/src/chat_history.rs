//! Protected local chat-history metadata (petname-first).
//!
//! The durable history file is always authenticated ciphertext. On macOS and
//! GNU/Linux its random encryption key lives in Keychain / Secret Service; on
//! Windows the payload is protected directly with user-scoped DPAPI. There is
//! deliberately no plaintext or mode-0600-key fallback.

use crate::sanitize::sanitize_terminal_text;
#[cfg(any(
    test,
    target_os = "macos",
    all(target_os = "linux", target_env = "gnu")
))]
use chacha20poly1305::{
    aead::{Aead, Payload},
    ChaCha20Poly1305, KeyInit, Nonce,
};
#[cfg(any(
    test,
    target_os = "macos",
    all(target_os = "linux", target_env = "gnu")
))]
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
#[cfg(any(
    test,
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
))]
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use zeroize::{Zeroize, Zeroizing};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChatHistoryEntry {
    pub message_id_hex: String,
    pub direction: String, // "out" | "in"
    pub peer_petname: String,
    pub peer_tag: String,
    pub peer_pub_hex: String,
    pub created_at_ms: u64,
    pub delivery: String,
    /// Sanitized local preview (never raw control chars). Empty when redacted.
    pub preview: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChatHistory {
    pub entries: Vec<ChatHistoryEntry>,
}

#[derive(Debug, thiserror::Error)]
pub enum ChatHistoryError {
    #[error("chat history I/O failed: {0}")]
    Io(String),
    #[error("protected chat-history backend unavailable: {0}")]
    ProtectedStoreUnavailable(String),
    #[error("protected chat-history key is missing")]
    MissingProtectedKey,
    #[error("protected chat-history key is corrupt")]
    CorruptProtectedKey,
    #[error("chat history is corrupt")]
    Corrupt,
    #[error("chat history authentication failed (wrong key or tampered file)")]
    AuthenticationFailed,
    #[error("chat history exceeds the local size limit")]
    TooLarge,
    #[error("legacy plaintext chat history is malformed; original file was preserved")]
    MalformedLegacyPlaintext,
    #[error("chat history has unsafe file metadata")]
    UnsafeFileMetadata,
}

/// Injectable protection boundary. Production callers use
/// [`PlatformChatHistoryProtector`]; deterministic in-memory implementations
/// let headless CI exercise all file semantics without weakening production.
trait ChatHistoryProtector: Send + Sync {
    fn protect(&self, data_dir: &Path, plaintext: &[u8]) -> Result<Vec<u8>, ChatHistoryError>;
    fn unprotect(&self, data_dir: &Path, ciphertext: &[u8]) -> Result<Vec<u8>, ChatHistoryError>;
}

#[derive(Debug, Default, Clone, Copy)]
struct PlatformChatHistoryProtector;

const MAX_ENTRIES: usize = 2_000;
const MAX_HISTORY_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_HISTORY_PLAINTEXT_BYTES: usize = 4 * 1024 * 1024;
const HISTORY_MAGIC: &[u8; 8] = b"RVNHIST1";
#[cfg(any(
    test,
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
))]
const HISTORY_AAD_DOMAIN: &[u8] = b"raven/chat-history/v1";
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
const HISTORY_KEY_SERVICE: &str = "app.raven.node.chat-history.v1";
#[cfg(all(target_os = "linux", target_env = "gnu"))]
const HISTORY_KEY_LABEL: &str = "RAVEN protected local chat history";
const MAX_MESSAGE_ID_CHARS: usize = 128;
const MAX_DIRECTION_CHARS: usize = 8;
const MAX_PETNAME_CHARS: usize = 512;
const MAX_TAG_CHARS: usize = 512;
const MAX_PUBLIC_KEY_CHARS: usize = 256;
const MAX_DELIVERY_CHARS: usize = 64;
const MAX_PREVIEW_CHARS: usize = 120;

pub fn history_path(data_dir: &Path) -> PathBuf {
    // Retain the historical path for compatibility. Its contents are binary,
    // authenticated ciphertext after the first protected save/migration.
    data_dir.join("chat_history.json")
}

pub fn blocked_path(data_dir: &Path) -> PathBuf {
    data_dir.join("blocked_pubs.json")
}

fn history_lock_path(data_dir: &Path) -> PathBuf {
    data_dir.join(".chat_history.lock.sqlite")
}

struct HistoryLock {
    _connection: rusqlite::Connection,
}

impl HistoryLock {
    fn acquire(data_dir: &Path) -> Result<Self, ChatHistoryError> {
        std::fs::create_dir_all(data_dir).map_err(|e| ChatHistoryError::Io(e.to_string()))?;
        let connection = rusqlite::Connection::open(history_lock_path(data_dir))
            .map_err(|e| ChatHistoryError::Io(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                history_lock_path(data_dir),
                std::fs::Permissions::from_mode(0o600),
            )
            .map_err(|e| ChatHistoryError::Io(e.to_string()))?;
        }
        connection
            .busy_timeout(Duration::from_secs(10))
            .map_err(|e| ChatHistoryError::Io(e.to_string()))?;
        connection
            .execute_batch("BEGIN EXCLUSIVE")
            .map_err(|e| ChatHistoryError::Io(format!("history lock: {e}")))?;
        Ok(Self {
            _connection: connection,
        })
    }
}

impl ChatHistory {
    /// Load protected history. Missing files are an empty history; existing
    /// files never degrade to empty on keychain, parse, or authentication error.
    pub fn load(data_dir: &Path) -> Result<Self, ChatHistoryError> {
        Self::load_with_protector(data_dir, &PlatformChatHistoryProtector)
    }

    fn load_with_protector(
        data_dir: &Path,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<Self, ChatHistoryError> {
        let _lock = HistoryLock::acquire(data_dir)?;
        Self::load_unlocked(data_dir, protector)
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), ChatHistoryError> {
        self.save_with_protector(data_dir, &PlatformChatHistoryProtector)
    }

    fn save_with_protector(
        &self,
        data_dir: &Path,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<(), ChatHistoryError> {
        let _lock = HistoryLock::acquire(data_dir)?;
        self.save_unlocked(data_dir, protector)
    }

    /// Append and persist under one inter-process lock, avoiding lost updates
    /// when ash and another local process write concurrently.
    pub fn append_persisted(
        data_dir: &Path,
        entry: ChatHistoryEntry,
    ) -> Result<(), ChatHistoryError> {
        Self::append_persisted_with_protector(data_dir, entry, &PlatformChatHistoryProtector)
    }

    fn append_persisted_with_protector(
        data_dir: &Path,
        entry: ChatHistoryEntry,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<(), ChatHistoryError> {
        let _lock = HistoryLock::acquire(data_dir)?;
        let mut history = Self::load_unlocked(data_dir, protector)?;
        history.append(entry);
        history.save_unlocked(data_dir, protector)
    }

    /// Clear one peer and persist under the same lock used by append/migration.
    pub fn clear_peer_persisted(data_dir: &Path, pub_hex: &str) -> Result<(), ChatHistoryError> {
        Self::clear_peer_persisted_with_protector(data_dir, pub_hex, &PlatformChatHistoryProtector)
    }

    fn clear_peer_persisted_with_protector(
        data_dir: &Path,
        pub_hex: &str,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<(), ChatHistoryError> {
        let _lock = HistoryLock::acquire(data_dir)?;
        let mut history = Self::load_unlocked(data_dir, protector)?;
        history.clear_peer(pub_hex);
        history.save_unlocked(data_dir, protector)
    }

    fn load_unlocked(
        data_dir: &Path,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<Self, ChatHistoryError> {
        let path = history_path(data_dir);
        let Some(bytes) = read_history_file(&path)? else {
            return Ok(Self::default());
        };
        let mut bytes = Zeroizing::new(bytes);

        if bytes.starts_with(HISTORY_MAGIC) {
            validate_private_file_metadata(&path)?;
            let plaintext = protector.unprotect(data_dir, &bytes[HISTORY_MAGIC.len()..])?;
            let plaintext = Zeroizing::new(plaintext);
            if plaintext.len() > MAX_HISTORY_PLAINTEXT_BYTES {
                return Err(ChatHistoryError::TooLarge);
            }
            let history: Self =
                serde_json::from_slice(&plaintext).map_err(|_| ChatHistoryError::Corrupt)?;
            history.validate()?;
            return Ok(history);
        }

        // One-time, crash-safe migration from the old JSON file. The old file
        // remains untouched unless encryption, protected-key persistence,
        // ciphertext fsync, and atomic replacement all succeed.
        let first = bytes
            .iter()
            .copied()
            .find(|byte| !byte.is_ascii_whitespace());
        if first == Some(b'{') {
            let mut history: Self = serde_json::from_slice(&bytes)
                .map_err(|_| ChatHistoryError::MalformedLegacyPlaintext)?;
            history.normalize_all();
            history.validate()?;
            history.save_unlocked(data_dir, protector)?;
            bytes.zeroize();
            return Ok(history);
        }

        Err(ChatHistoryError::Corrupt)
    }

    fn save_unlocked(
        &self,
        data_dir: &Path,
        protector: &dyn ChatHistoryProtector,
    ) -> Result<(), ChatHistoryError> {
        self.validate()?;
        let plaintext = serde_json::to_vec(self).map_err(|_| ChatHistoryError::Corrupt)?;
        let plaintext = Zeroizing::new(plaintext);
        if plaintext.len() > MAX_HISTORY_PLAINTEXT_BYTES {
            return Err(ChatHistoryError::TooLarge);
        }
        let protected = protector.protect(data_dir, &plaintext)?;
        let total_len = HISTORY_MAGIC
            .len()
            .checked_add(protected.len())
            .ok_or(ChatHistoryError::TooLarge)?;
        if total_len as u64 > MAX_HISTORY_FILE_BYTES {
            return Err(ChatHistoryError::TooLarge);
        }
        let mut encoded = Vec::with_capacity(total_len);
        encoded.extend_from_slice(HISTORY_MAGIC);
        encoded.extend_from_slice(&protected);
        atomic_write_private(&history_path(data_dir), &encoded)
    }

    pub fn append(&mut self, mut entry: ChatHistoryEntry) {
        normalize_entry(&mut entry);
        self.entries.push(entry);
        if self.entries.len() > MAX_ENTRIES {
            let drop = self.entries.len() - MAX_ENTRIES;
            self.entries.drain(0..drop);
        }
    }

    pub fn for_peer<'a>(&'a self, pub_hex: &str) -> Vec<&'a ChatHistoryEntry> {
        let want = pub_hex.trim().to_lowercase();
        self.entries
            .iter()
            .filter(|e| e.peer_pub_hex.eq_ignore_ascii_case(&want))
            .collect()
    }

    pub fn clear_peer(&mut self, pub_hex: &str) {
        let want = pub_hex.trim().to_lowercase();
        self.entries
            .retain(|e| !e.peer_pub_hex.eq_ignore_ascii_case(&want));
    }

    fn normalize_all(&mut self) {
        for entry in &mut self.entries {
            normalize_entry(entry);
        }
        if self.entries.len() > MAX_ENTRIES {
            let drop = self.entries.len() - MAX_ENTRIES;
            self.entries.drain(0..drop);
        }
    }

    fn validate(&self) -> Result<(), ChatHistoryError> {
        if self.entries.len() > MAX_ENTRIES {
            return Err(ChatHistoryError::TooLarge);
        }
        for entry in &self.entries {
            let fields = [
                (&entry.message_id_hex, MAX_MESSAGE_ID_CHARS),
                (&entry.direction, MAX_DIRECTION_CHARS),
                (&entry.peer_petname, MAX_PETNAME_CHARS),
                (&entry.peer_tag, MAX_TAG_CHARS),
                (&entry.peer_pub_hex, MAX_PUBLIC_KEY_CHARS),
                (&entry.delivery, MAX_DELIVERY_CHARS),
                (&entry.preview, MAX_PREVIEW_CHARS),
            ];
            if fields
                .iter()
                .any(|(value, maximum)| value.chars().count() > *maximum)
            {
                return Err(ChatHistoryError::TooLarge);
            }
            if truncate_sanitized(&entry.message_id_hex, MAX_MESSAGE_ID_CHARS)
                != entry.message_id_hex
                || truncate_sanitized(&entry.direction, MAX_DIRECTION_CHARS) != entry.direction
                || truncate_sanitized(&entry.peer_petname, MAX_PETNAME_CHARS) != entry.peer_petname
                || truncate_sanitized(&entry.peer_tag, MAX_TAG_CHARS) != entry.peer_tag
                || truncate_sanitized(&entry.peer_pub_hex, MAX_PUBLIC_KEY_CHARS)
                    != entry.peer_pub_hex
                || truncate_sanitized(&entry.delivery, MAX_DELIVERY_CHARS) != entry.delivery
                || truncate_sanitized(&entry.preview, MAX_PREVIEW_CHARS) != entry.preview
            {
                return Err(ChatHistoryError::Corrupt);
            }
        }
        Ok(())
    }
}

fn normalize_entry(entry: &mut ChatHistoryEntry) {
    entry.message_id_hex = truncate_sanitized(&entry.message_id_hex, MAX_MESSAGE_ID_CHARS);
    entry.direction = truncate_sanitized(&entry.direction, MAX_DIRECTION_CHARS);
    entry.peer_petname = truncate_sanitized(&entry.peer_petname, MAX_PETNAME_CHARS);
    entry.peer_tag = truncate_sanitized(&entry.peer_tag, MAX_TAG_CHARS);
    entry.peer_pub_hex =
        truncate_sanitized(&entry.peer_pub_hex, MAX_PUBLIC_KEY_CHARS).to_lowercase();
    entry.delivery = truncate_sanitized(&entry.delivery, MAX_DELIVERY_CHARS);
    entry.preview = truncate_sanitized(&entry.preview, MAX_PREVIEW_CHARS);
}

fn truncate_sanitized(value: &str, maximum: usize) -> String {
    sanitize_terminal_text(value)
        .chars()
        .map(|character| match character {
            '\t' | '\n' | '\r' => ' ',
            other => other,
        })
        .take(maximum)
        .collect()
}

fn read_history_file(path: &Path) -> Result<Option<Vec<u8>>, ChatHistoryError> {
    let path_metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(ChatHistoryError::Io(error.to_string())),
    };
    validate_regular_history_file(path)?;
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) => return Err(ChatHistoryError::Io(error.to_string())),
    };
    let metadata = file
        .metadata()
        .map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if !metadata.is_file() {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    if metadata.len() != path_metadata.len() {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.dev() != path_metadata.dev() || metadata.ino() != path_metadata.ino() {
            return Err(ChatHistoryError::UnsafeFileMetadata);
        }
    }
    if metadata.len() > MAX_HISTORY_FILE_BYTES {
        return Err(ChatHistoryError::TooLarge);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if bytes.len() as u64 > MAX_HISTORY_FILE_BYTES {
        return Err(ChatHistoryError::TooLarge);
    }
    Ok(Some(bytes))
}

#[cfg(unix)]
fn validate_regular_history_file(path: &Path) -> Result<(), ChatHistoryError> {
    use std::os::unix::fs::MetadataExt;
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() || metadata.nlink() != 1
    {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_regular_history_file(path: &Path) -> Result<(), ChatHistoryError> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    Ok(())
}

#[cfg(unix)]
fn validate_private_file_metadata(path: &Path) -> Result<(), ChatHistoryError> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_private_file_metadata(path: &Path) -> Result<(), ChatHistoryError> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(ChatHistoryError::UnsafeFileMetadata);
    }
    Ok(())
}

fn atomic_write_private(path: &Path, contents: &[u8]) -> Result<(), ChatHistoryError> {
    let parent = path
        .parent()
        .ok_or_else(|| ChatHistoryError::Io("history path has no parent".into()))?;
    std::fs::create_dir_all(parent).map_err(|error| ChatHistoryError::Io(error.to_string()))?;

    let (temporary, mut file) = loop {
        let candidate = parent.join(format!(".chat_history.tmp.{:016x}", rand::random::<u64>()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&candidate) {
            Ok(file) => break (candidate, file),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ChatHistoryError::Io(error.to_string())),
        }
    };

    let prepared = file.write_all(contents).and_then(|_| file.sync_all());
    drop(file);
    if let Err(error) = prepared {
        let _ = std::fs::remove_file(&temporary);
        return Err(ChatHistoryError::Io(error.to_string()));
    }

    if let Err(error) = replace_file(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }

    #[cfg(unix)]
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| ChatHistoryError::Io(error.to_string()))?;
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(temporary: &Path, destination: &Path) -> Result<(), ChatHistoryError> {
    std::fs::rename(temporary, destination).map_err(|error| ChatHistoryError::Io(error.to_string()))
}

#[cfg(windows)]
fn replace_file(temporary: &Path, destination: &Path) -> Result<(), ChatHistoryError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let mut from: Vec<u16> = temporary.as_os_str().encode_wide().collect();
    from.push(0);
    let mut to: Vec<u16> = destination.as_os_str().encode_wide().collect();
    to.push(0);
    let ok = unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        return Err(ChatHistoryError::Io(
            "atomic history replacement failed".into(),
        ));
    }
    Ok(())
}

#[cfg(any(
    test,
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
))]
fn history_scope(data_dir: &Path) -> [u8; 32] {
    let canonical = std::fs::canonicalize(data_dir).unwrap_or_else(|_| data_dir.to_path_buf());
    let mut hasher = Sha256::new();
    hasher.update(HISTORY_AAD_DOMAIN);
    hasher.update(b"/");
    hasher.update(canonical.to_string_lossy().as_bytes());
    hasher.finalize().into()
}

#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
fn history_account(data_dir: &Path) -> String {
    hex::encode(history_scope(data_dir))
}

#[cfg(any(
    test,
    target_os = "macos",
    all(target_os = "linux", target_env = "gnu")
))]
fn aead_protect(
    key: &[u8; 32],
    data_dir: &Path,
    plaintext: &[u8],
) -> Result<Vec<u8>, ChatHistoryError> {
    let cipher =
        ChaCha20Poly1305::new_from_slice(key).map_err(|_| ChatHistoryError::CorruptProtectedKey)?;
    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let aad = history_scope(data_dir);
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| ChatHistoryError::AuthenticationFailed)?;
    let mut result = Vec::with_capacity(nonce_bytes.len() + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

#[cfg(any(
    test,
    target_os = "macos",
    all(target_os = "linux", target_env = "gnu")
))]
fn aead_unprotect(
    key: &[u8; 32],
    data_dir: &Path,
    protected: &[u8],
) -> Result<Vec<u8>, ChatHistoryError> {
    if protected.len() < 12 + 16 {
        return Err(ChatHistoryError::Corrupt);
    }
    let cipher =
        ChaCha20Poly1305::new_from_slice(key).map_err(|_| ChatHistoryError::CorruptProtectedKey)?;
    let aad = history_scope(data_dir);
    cipher
        .decrypt(
            Nonce::from_slice(&protected[..12]),
            Payload {
                msg: &protected[12..],
                aad: &aad,
            },
        )
        .map_err(|_| ChatHistoryError::AuthenticationFailed)
}

#[cfg(target_os = "macos")]
fn platform_get_key(data_dir: &Path) -> Result<Option<Zeroizing<[u8; 32]>>, ChatHistoryError> {
    use security_framework::passwords::get_generic_password;
    let account = history_account(data_dir);
    match get_generic_password(HISTORY_KEY_SERVICE, &account) {
        Ok(mut bytes) => {
            if bytes.len() != 32 {
                bytes.zeroize();
                return Err(ChatHistoryError::CorruptProtectedKey);
            }
            let mut key = Zeroizing::new([0u8; 32]);
            key.copy_from_slice(&bytes);
            bytes.zeroize();
            Ok(Some(key))
        }
        Err(error) if error.code() == -25_300 => Ok(None),
        Err(error) => Err(ChatHistoryError::ProtectedStoreUnavailable(format!(
            "keychain read failed: {error}"
        ))),
    }
}

#[cfg(target_os = "macos")]
fn platform_set_key(data_dir: &Path, key: &[u8; 32]) -> Result<(), ChatHistoryError> {
    use security_framework::passwords::set_generic_password;
    let account = history_account(data_dir);
    set_generic_password(HISTORY_KEY_SERVICE, &account, key).map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!("keychain update failed: {error}"))
    })
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn platform_get_key(data_dir: &Path) -> Result<Option<Zeroizing<[u8; 32]>>, ChatHistoryError> {
    use secret_service::{EncryptionType, SecretService};
    let service = SecretService::new(EncryptionType::Dh).map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!(
            "secret-service connection failed: {error}"
        ))
    })?;
    let collection = service.get_default_collection().map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!(
            "secret-service collection failed: {error}"
        ))
    })?;
    if collection.is_locked() {
        collection.unlock().map_err(|error| {
            ChatHistoryError::ProtectedStoreUnavailable(format!(
                "secret-service unlock failed: {error}"
            ))
        })?;
    }
    let account = history_account(data_dir);
    let items = collection
        .search_items(vec![
            ("service", HISTORY_KEY_SERVICE),
            ("account", account.as_str()),
        ])
        .map_err(|error| {
            ChatHistoryError::ProtectedStoreUnavailable(format!(
                "secret-service search failed: {error}"
            ))
        })?;
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    let mut bytes = item.get_secret().map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!("secret-service read failed: {error}"))
    })?;
    if bytes.len() != 32 {
        bytes.zeroize();
        return Err(ChatHistoryError::CorruptProtectedKey);
    }
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&bytes);
    bytes.zeroize();
    Ok(Some(key))
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn platform_set_key(data_dir: &Path, key: &[u8; 32]) -> Result<(), ChatHistoryError> {
    use secret_service::{EncryptionType, SecretService};
    let service = SecretService::new(EncryptionType::Dh).map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!(
            "secret-service connection failed: {error}"
        ))
    })?;
    let collection = service.get_default_collection().map_err(|error| {
        ChatHistoryError::ProtectedStoreUnavailable(format!(
            "secret-service collection failed: {error}"
        ))
    })?;
    if collection.is_locked() {
        collection.unlock().map_err(|error| {
            ChatHistoryError::ProtectedStoreUnavailable(format!(
                "secret-service unlock failed: {error}"
            ))
        })?;
    }
    let account = history_account(data_dir);
    collection
        .create_item(
            HISTORY_KEY_LABEL,
            vec![
                ("service", HISTORY_KEY_SERVICE),
                ("account", account.as_str()),
            ],
            key,
            true,
            "application/octet-stream",
        )
        .map_err(|error| {
            ChatHistoryError::ProtectedStoreUnavailable(format!(
                "secret-service update failed: {error}"
            ))
        })?;
    Ok(())
}

#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
fn load_platform_key(
    data_dir: &Path,
    create: bool,
) -> Result<Zeroizing<[u8; 32]>, ChatHistoryError> {
    if let Some(key) = platform_get_key(data_dir)? {
        return Ok(key);
    }
    if !create {
        return Err(ChatHistoryError::MissingProtectedKey);
    }
    let mut generated = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(&mut *generated);
    platform_set_key(data_dir, &generated)?;
    let confirmed = platform_get_key(data_dir)?.ok_or(ChatHistoryError::MissingProtectedKey)?;
    if *confirmed != *generated {
        return Err(ChatHistoryError::ProtectedStoreUnavailable(
            "concurrent protected-key initialization".into(),
        ));
    }
    Ok(confirmed)
}

impl ChatHistoryProtector for PlatformChatHistoryProtector {
    fn protect(&self, data_dir: &Path, plaintext: &[u8]) -> Result<Vec<u8>, ChatHistoryError> {
        #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
        {
            let key = load_platform_key(data_dir, true)?;
            aead_protect(&key, data_dir, plaintext)
        }
        #[cfg(windows)]
        {
            return dpapi_protect_history(data_dir, plaintext);
        }
        #[cfg(not(any(
            target_os = "macos",
            windows,
            all(target_os = "linux", target_env = "gnu")
        )))]
        {
            let _ = (data_dir, plaintext);
            Err(ChatHistoryError::ProtectedStoreUnavailable(
                "no supported platform-protected backend".into(),
            ))
        }
    }

    fn unprotect(&self, data_dir: &Path, ciphertext: &[u8]) -> Result<Vec<u8>, ChatHistoryError> {
        #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
        {
            let key = load_platform_key(data_dir, false)?;
            aead_unprotect(&key, data_dir, ciphertext)
        }
        #[cfg(windows)]
        {
            return dpapi_unprotect_history(data_dir, ciphertext);
        }
        #[cfg(not(any(
            target_os = "macos",
            windows,
            all(target_os = "linux", target_env = "gnu")
        )))]
        {
            let _ = (data_dir, ciphertext);
            Err(ChatHistoryError::ProtectedStoreUnavailable(
                "no supported platform-protected backend".into(),
            ))
        }
    }
}

#[cfg(windows)]
fn dpapi_protect_history(data_dir: &Path, plaintext: &[u8]) -> Result<Vec<u8>, ChatHistoryError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut input = CRYPT_INTEGER_BLOB {
        cbData: plaintext
            .len()
            .try_into()
            .map_err(|_| ChatHistoryError::TooLarge)?,
        pbData: plaintext.as_ptr() as *mut u8,
    };
    let scope = history_scope(data_dir);
    let mut entropy = CRYPT_INTEGER_BLOB {
        cbData: scope.len() as u32,
        pbData: scope.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut input,
            std::ptr::null(),
            &mut entropy,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 || output.pbData.is_null() || output.cbData == 0 {
        return Err(ChatHistoryError::ProtectedStoreUnavailable(
            "CryptProtectData failed".into(),
        ));
    }
    let protected =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(output.pbData as _);
    }
    Ok(protected)
}

#[cfg(windows)]
fn dpapi_unprotect_history(
    data_dir: &Path,
    ciphertext: &[u8],
) -> Result<Vec<u8>, ChatHistoryError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut input = CRYPT_INTEGER_BLOB {
        cbData: ciphertext
            .len()
            .try_into()
            .map_err(|_| ChatHistoryError::TooLarge)?,
        pbData: ciphertext.as_ptr() as *mut u8,
    };
    let scope = history_scope(data_dir);
    let mut entropy = CRYPT_INTEGER_BLOB {
        cbData: scope.len() as u32,
        pbData: scope.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            std::ptr::null_mut(),
            &mut entropy,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 || output.pbData.is_null() {
        return Err(ChatHistoryError::AuthenticationFailed);
    }
    let plaintext =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(output.pbData as _);
    }
    Ok(plaintext)
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct BlockList {
    pub pub_hex: Vec<String>,
}

impl BlockList {
    pub fn load(data_dir: &Path) -> Self {
        let path = blocked_path(data_dir);
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&raw).unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), String> {
        std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
        let raw = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(blocked_path(data_dir), raw).map_err(|e| e.to_string())
    }

    pub fn is_blocked(&self, pub_hex: &str) -> bool {
        let want = pub_hex.trim().to_lowercase();
        self.pub_hex.iter().any(|p| p.eq_ignore_ascii_case(&want))
    }

    pub fn block(&mut self, pub_hex: &str) {
        let h = pub_hex.trim().to_lowercase();
        if !self.is_blocked(&h) {
            self.pub_hex.push(h);
        }
    }

    pub fn unblock(&mut self, pub_hex: &str) {
        let want = pub_hex.trim().to_lowercase();
        self.pub_hex.retain(|p| !p.eq_ignore_ascii_case(&want));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    struct TestProtector {
        key: [u8; 32],
        available: bool,
    }

    impl TestProtector {
        fn new(byte: u8) -> Self {
            Self {
                key: [byte; 32],
                available: true,
            }
        }
    }

    impl ChatHistoryProtector for TestProtector {
        fn protect(&self, data_dir: &Path, plaintext: &[u8]) -> Result<Vec<u8>, ChatHistoryError> {
            if !self.available {
                return Err(ChatHistoryError::ProtectedStoreUnavailable("test".into()));
            }
            aead_protect(&self.key, data_dir, plaintext)
        }

        fn unprotect(
            &self,
            data_dir: &Path,
            ciphertext: &[u8],
        ) -> Result<Vec<u8>, ChatHistoryError> {
            if !self.available {
                return Err(ChatHistoryError::ProtectedStoreUnavailable("test".into()));
            }
            aead_unprotect(&self.key, data_dir, ciphertext)
        }
    }

    fn sample_entry() -> ChatHistoryEntry {
        ChatHistoryEntry {
            message_id_hex: "aabbccdd00112233".into(),
            direction: "out".into(),
            peer_petname: "Alice Secret Label\x1b[31m".into(),
            peer_tag: "alice-private-tag".into(),
            peer_pub_hex: "abcdef0123456789".into(),
            created_at_ms: 1,
            delivery: "queued".into(),
            preview: "confidential hello\nthere".into(),
        }
    }

    #[test]
    fn protected_roundtrip_sanitizes_and_disk_has_no_plaintext_identifiers() {
        let dir = tempdir().unwrap();
        let protector = TestProtector::new(7);
        let mut history = ChatHistory::default();
        history.append(sample_entry());
        history.save_with_protector(dir.path(), &protector).unwrap();
        let disk = std::fs::read(history_path(dir.path())).unwrap();
        assert!(disk.starts_with(HISTORY_MAGIC));
        for forbidden in [
            b"Alice Secret Label".as_slice(),
            b"alice-private-tag".as_slice(),
            b"abcdef0123456789".as_slice(),
            b"aabbccdd00112233".as_slice(),
            b"confidential hello".as_slice(),
        ] {
            assert!(!disk
                .windows(forbidden.len())
                .any(|window| window == forbidden));
        }

        let loaded = ChatHistory::load_with_protector(dir.path(), &protector).unwrap();
        assert_eq!(loaded.entries.len(), 1);
        assert!(!loaded.entries[0].peer_petname.contains('\x1b'));
        assert_eq!(loaded.entries[0].preview, "confidential hello there");
    }

    #[cfg(unix)]
    #[test]
    fn protected_file_is_owner_only_and_atomically_replaced() {
        use std::io::{Read, Seek, SeekFrom};
        use std::os::unix::fs::PermissionsExt;

        let dir = tempdir().unwrap();
        let protector = TestProtector::new(8);
        let mut first = ChatHistory::default();
        first.append(sample_entry());
        first.save_with_protector(dir.path(), &protector).unwrap();
        let path = history_path(dir.path());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let mut old_handle = File::open(&path).unwrap();
        let old_disk = std::fs::read(&path).unwrap();

        let mut second = first.clone();
        let mut entry = sample_entry();
        entry.preview = "replacement text".into();
        second.append(entry);
        second.save_with_protector(dir.path(), &protector).unwrap();

        old_handle.seek(SeekFrom::Start(0)).unwrap();
        let mut old_handle_bytes = Vec::new();
        old_handle.read_to_end(&mut old_handle_bytes).unwrap();
        assert_eq!(
            old_handle_bytes, old_disk,
            "rename replaced the inode atomically"
        );
        assert!(std::fs::read_dir(dir.path()).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".chat_history.tmp.")
        }));
    }

    #[test]
    fn tamper_and_corrupt_files_fail_closed_without_reset() {
        let dir = tempdir().unwrap();
        let protector = TestProtector::new(9);
        let mut history = ChatHistory::default();
        history.append(sample_entry());
        history.save_with_protector(dir.path(), &protector).unwrap();
        let path = history_path(dir.path());
        let mut tampered = std::fs::read(&path).unwrap();
        *tampered.last_mut().unwrap() ^= 0x80;
        std::fs::write(&path, &tampered).unwrap();
        let error = ChatHistory::load_with_protector(dir.path(), &protector).unwrap_err();
        assert!(matches!(error, ChatHistoryError::AuthenticationFailed));
        assert_eq!(std::fs::read(&path).unwrap(), tampered);

        let corrupt = b"not-json-and-not-protected";
        std::fs::write(&path, corrupt).unwrap();
        let error = ChatHistory::load_with_protector(dir.path(), &protector).unwrap_err();
        assert!(matches!(error, ChatHistoryError::Corrupt));
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
    }

    #[test]
    fn legacy_plaintext_migrates_only_after_protected_write_succeeds() {
        let dir = tempdir().unwrap();
        let path = history_path(dir.path());
        let mut legacy = ChatHistory::default();
        legacy.append(sample_entry());
        let plaintext = serde_json::to_vec_pretty(&legacy).unwrap();
        std::fs::write(&path, &plaintext).unwrap();

        let unavailable = TestProtector {
            key: [10; 32],
            available: false,
        };
        assert!(matches!(
            ChatHistory::load_with_protector(dir.path(), &unavailable).unwrap_err(),
            ChatHistoryError::ProtectedStoreUnavailable(_)
        ));
        assert_eq!(std::fs::read(&path).unwrap(), plaintext);

        let protector = TestProtector::new(10);
        let loaded = ChatHistory::load_with_protector(dir.path(), &protector).unwrap();
        assert_eq!(loaded.entries.len(), 1);
        let migrated = std::fs::read(&path).unwrap();
        assert!(migrated.starts_with(HISTORY_MAGIC));
        assert!(!migrated
            .windows(b"Alice Secret Label".len())
            .any(|window| window == b"Alice Secret Label"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn legacy_hardlink_is_refused_so_no_plaintext_alias_is_left_behind() {
        let dir = tempdir().unwrap();
        let path = history_path(dir.path());
        let alias = dir.path().join("legacy-alias.json");
        let mut legacy = ChatHistory::default();
        legacy.append(sample_entry());
        let plaintext = serde_json::to_vec_pretty(&legacy).unwrap();
        std::fs::write(&path, &plaintext).unwrap();
        std::fs::hard_link(&path, &alias).unwrap();

        let error =
            ChatHistory::load_with_protector(dir.path(), &TestProtector::new(15)).unwrap_err();
        assert!(matches!(error, ChatHistoryError::UnsafeFileMetadata));
        assert_eq!(std::fs::read(&path).unwrap(), plaintext);
        assert_eq!(std::fs::read(&alias).unwrap(), plaintext);
    }

    #[test]
    fn malformed_legacy_plaintext_is_preserved() {
        let dir = tempdir().unwrap();
        let path = history_path(dir.path());
        let malformed = b"{\"entries\":[";
        std::fs::write(&path, malformed).unwrap();
        let error =
            ChatHistory::load_with_protector(dir.path(), &TestProtector::new(11)).unwrap_err();
        assert!(matches!(error, ChatHistoryError::MalformedLegacyPlaintext));
        assert_eq!(std::fs::read(&path).unwrap(), malformed);
    }

    #[test]
    fn unavailable_backend_never_writes_plaintext_or_overwrites_ciphertext() {
        let dir = tempdir().unwrap();
        let unavailable = TestProtector {
            key: [12; 32],
            available: false,
        };
        let mut history = ChatHistory::default();
        history.append(sample_entry());
        assert!(history
            .save_with_protector(dir.path(), &unavailable)
            .is_err());
        assert!(!history_path(dir.path()).exists());

        let good = TestProtector::new(12);
        history.save_with_protector(dir.path(), &good).unwrap();
        let original = std::fs::read(history_path(dir.path())).unwrap();
        let error =
            ChatHistory::append_persisted_with_protector(dir.path(), sample_entry(), &unavailable)
                .unwrap_err();
        assert!(matches!(
            error,
            ChatHistoryError::ProtectedStoreUnavailable(_)
        ));
        assert_eq!(std::fs::read(history_path(dir.path())).unwrap(), original);
    }

    #[test]
    fn wrong_key_fails_authentication() {
        let dir = tempdir().unwrap();
        let mut history = ChatHistory::default();
        history.append(sample_entry());
        history
            .save_with_protector(dir.path(), &TestProtector::new(13))
            .unwrap();
        let error =
            ChatHistory::load_with_protector(dir.path(), &TestProtector::new(14)).unwrap_err();
        assert!(matches!(error, ChatHistoryError::AuthenticationFailed));
    }

    #[test]
    fn block_list() {
        let dir = tempdir().unwrap();
        let mut blocklist = BlockList::default();
        blocklist.block("AABB");
        assert!(blocklist.is_blocked("aabb"));
        blocklist.save(dir.path()).unwrap();
        assert!(BlockList::load(dir.path()).is_blocked("aabb"));
    }
}
