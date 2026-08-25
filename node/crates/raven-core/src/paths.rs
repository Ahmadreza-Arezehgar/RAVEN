//! Shared Raven data-dir and LAN bind defaults for ash and raven-node.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// Default LAN listener for `raven-node service` (reachable from other LAN hosts).
pub const DEFAULT_LAN_LISTEN: &str = "0.0.0.0:7420";
/// Mock BLE stays loopback-only.
pub const DEFAULT_BLE_LISTEN: &str = "127.0.0.1:7421";
/// Shared device_id for the local cert + prekey on this node.
pub const PRIMARY_DEVICE_ID: &str = "ash-primary";

/// Resolve the shared Raven profile directory.
///
/// Order: `RAVEN_DATA_DIR`, else `ASH_DATA_DIR`, else if `~/.raven-ash` exists
/// and `~/.raven` does not keep the legacy ash dir, else `~/.raven`.
pub fn default_raven_data_dir() -> PathBuf {
    resolve_raven_data_dir(
        std::env::var_os("RAVEN_DATA_DIR").map(PathBuf::from),
        std::env::var_os("ASH_DATA_DIR").map(PathBuf::from),
        std::env::var_os("HOME").map(PathBuf::from),
    )
}

pub fn resolve_raven_data_dir(
    raven_data_dir: Option<PathBuf>,
    ash_data_dir: Option<PathBuf>,
    home: Option<PathBuf>,
) -> PathBuf {
    if let Some(p) = nonempty(raven_data_dir) {
        return p;
    }
    if let Some(p) = nonempty(ash_data_dir) {
        return p;
    }
    let Some(home) = home else {
        return PathBuf::from("./raven-data");
    };
    let raven = home.join(".raven");
    let raven_ash = home.join(".raven-ash");
    if raven_ash.is_dir() && !raven.exists() {
        return raven_ash;
    }
    raven
}

fn nonempty(p: Option<PathBuf>) -> Option<PathBuf> {
    p.filter(|p| !p.as_os_str().is_empty())
}

/// Cross-process exclusive lock via a small SQLite file (BEGIN EXCLUSIVE).
/// Holds until dropped. Used for peer-cache / registry RMW that must not race.
pub struct DataDirLock {
    _connection: rusqlite::Connection,
}

impl DataDirLock {
    pub fn acquire(data_dir: &Path, lock_file_name: &str) -> Result<Self, String> {
        std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
        let path = data_dir.join(lock_file_name);
        let connection = rusqlite::Connection::open(&path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        connection
            .busy_timeout(Duration::from_secs(10))
            .map_err(|e| e.to_string())?;
        connection
            .execute_batch("BEGIN EXCLUSIVE")
            .map_err(|e| format!("data-dir lock {lock_file_name}: {e}"))?;
        Ok(Self {
            _connection: connection,
        })
    }
}

/// Atomically replace `path` (temp + rename) with owner-only mode on Unix.
/// On Windows the temp file is created exclusively, synced, then renamed over
/// the destination (MoveFileEx REPLACE_EXISTING) — never a torn partial write.
pub fn atomic_write_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "atomic write: missing parent".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut rng = 0u64;
    for byte in contents.iter().take(8) {
        rng = rng.wrapping_mul(16777619) ^ u64::from(*byte);
    }
    rng ^= std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    let tmp = parent.join(format!(
        ".{}.tmp.{:016x}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("raven"),
        rng
    ));

    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let write = (|| -> Result<(), String> {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&tmp)
                .map_err(|e| e.to_string())?;
            f.set_permissions(std::fs::Permissions::from_mode(0o600))
                .map_err(|e| e.to_string())?;
            f.write_all(contents).map_err(|e| e.to_string())?;
            f.sync_all().map_err(|e| e.to_string())?;
            Ok(())
        })();
        if let Err(e) = write {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        if let Err(e) = std::fs::rename(&tmp, path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        if let Ok(dir) = std::fs::File::open(parent) {
            let _ = dir.sync_all();
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        use std::io::Write;
        let write = (|| -> Result<(), String> {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&tmp)
                .map_err(|e| e.to_string())?;
            f.write_all(contents).map_err(|e| e.to_string())?;
            f.sync_all().map_err(|e| e.to_string())?;
            Ok(())
        })();
        if let Err(e) = write {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        if let Err(e) = std::fs::rename(&tmp, path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        Ok(())
    }
}

/// Create `path` exclusively with owner-only mode on Unix. Fails when the file
/// already exists. First-install writes of secret material must use this —
/// never a replace-capable write.
pub fn create_new_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "create-new write: missing parent".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| e.to_string())?;
        if let Err(e) = (|| -> Result<(), String> {
            f.set_permissions(std::fs::Permissions::from_mode(0o600))
                .map_err(|e| e.to_string())?;
            f.write_all(contents).map_err(|e| e.to_string())?;
            f.sync_all().map_err(|e| e.to_string())?;
            Ok(())
        })() {
            let _ = std::fs::remove_file(path);
            return Err(e);
        }
        if let Ok(dir) = std::fs::File::open(parent) {
            let _ = dir.sync_all();
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| e.to_string())?;
        if let Err(e) = (|| -> Result<(), String> {
            f.write_all(contents).map_err(|e| e.to_string())?;
            f.sync_all().map_err(|e| e.to_string())?;
            Ok(())
        })() {
            let _ = std::fs::remove_file(path);
            return Err(e);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raven_env_wins_over_ash_and_home() {
        let p = resolve_raven_data_dir(
            Some(PathBuf::from("/explicit/raven")),
            Some(PathBuf::from("/explicit/ash")),
            Some(PathBuf::from("/home/u")),
        );
        assert_eq!(p, PathBuf::from("/explicit/raven"));
    }

    #[test]
    fn ash_env_wins_when_raven_env_absent() {
        let p = resolve_raven_data_dir(
            None,
            Some(PathBuf::from("/explicit/ash")),
            Some(PathBuf::from("/home/u")),
        );
        assert_eq!(p, PathBuf::from("/explicit/ash"));
    }

    #[test]
    fn empty_env_values_are_ignored() {
        let home = tempfile::tempdir().unwrap();
        let p = resolve_raven_data_dir(
            Some(PathBuf::from("")),
            Some(PathBuf::from("")),
            Some(home.path().to_path_buf()),
        );
        assert_eq!(p, home.path().join(".raven"));
    }

    #[test]
    fn keeps_existing_raven_ash_when_raven_absent() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir(home.path().join(".raven-ash")).unwrap();
        let p = resolve_raven_data_dir(None, None, Some(home.path().to_path_buf()));
        assert_eq!(p, home.path().join(".raven-ash"));
    }

    #[test]
    fn prefers_raven_when_both_exist() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir(home.path().join(".raven-ash")).unwrap();
        std::fs::create_dir(home.path().join(".raven")).unwrap();
        let p = resolve_raven_data_dir(None, None, Some(home.path().to_path_buf()));
        assert_eq!(p, home.path().join(".raven"));
    }

    #[test]
    fn defaults_to_raven_when_neither_exists() {
        let home = tempfile::tempdir().unwrap();
        let p = resolve_raven_data_dir(None, None, Some(home.path().to_path_buf()));
        assert_eq!(p, home.path().join(".raven"));
    }

    #[test]
    fn missing_home_falls_back_to_local_raven_data() {
        let p = resolve_raven_data_dir(None, None, None);
        assert_eq!(p, PathBuf::from("./raven-data"));
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_is_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("contacts.json");
        atomic_write_private(&path, b"[]").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(std::fs::read(&path).unwrap(), b"[]");
    }

    #[test]
    fn create_new_private_never_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("identity.seed");
        create_new_private(&path, b"first").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        assert!(create_new_private(&path, b"second").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"first");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_replaces_existing_content() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        atomic_write_private(&path, b"v1").unwrap();
        atomic_write_private(&path, b"v2-longer").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"v2-longer");
    }
}
