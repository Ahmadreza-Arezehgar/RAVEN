//! Local node policy config (ash writes; raven-node reads). No secrets.

use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodePolicy {
    /// AUTO: bridge when both radios; user may force on/off.
    #[serde(default = "default_true")]
    pub bridge: bool,
    #[serde(default = "default_true")]
    pub store: bool,
    #[serde(default = "default_false")]
    pub relay: bool,
    /// When true, node also acts as chat endpoint (separate from BridgeSubsystem).
    #[serde(default = "default_true")]
    pub endpoint: bool,
    /// AUTO policy marker — ash may set false when user overrides.
    #[serde(default = "default_true")]
    pub auto_policy: bool,
}

fn default_true() -> bool {
    true
}
fn default_false() -> bool {
    false
}

impl Default for NodePolicy {
    fn default() -> Self {
        Self {
            bridge: true,
            store: true,
            relay: false,
            endpoint: true,
            auto_policy: true,
        }
    }
}

impl NodePolicy {
    /// Conservative runtime policy used when an existing policy cannot be
    /// read or parsed. A damaged policy must never silently re-enable a radio,
    /// relay, store, or endpoint role that an operator may have disabled.
    pub fn fail_closed() -> Self {
        Self {
            bridge: false,
            store: false,
            relay: false,
            endpoint: false,
            auto_policy: false,
        }
    }
}

#[derive(Error, Debug)]
pub enum PolicyError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn policy_path(data_dir: &Path) -> PathBuf {
    data_dir.join("node_policy.json")
}

pub fn load_policy(data_dir: &Path) -> NodePolicy {
    let path = policy_path(data_dir);
    match std::fs::read_to_string(&path) {
        Ok(raw) => serde_json::from_str(&raw).unwrap_or_else(|_| NodePolicy::fail_closed()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => NodePolicy::default(),
        Err(_) => NodePolicy::fail_closed(),
    }
}

static POLICY_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn next_policy_temp_path(data_dir: &Path) -> PathBuf {
    let serial = POLICY_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    data_dir.join(format!(
        ".node_policy.json.tmp-{}-{serial}",
        std::process::id()
    ))
}

fn create_policy_temp(data_dir: &Path) -> Result<(PathBuf, std::fs::File), std::io::Error> {
    // A crashed writer may leave a temp file, and operating-system PIDs can be
    // reused. Skip stale names instead of wedging all future policy updates.
    for _ in 0..128 {
        let temp = next_policy_temp_path(data_dir);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&temp) {
            Ok(file) => return Ok((temp, file)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "unable to reserve an atomic policy temp file",
    ))
}

#[cfg(windows)]
fn replace_atomically(from: &Path, to: &Path) -> Result<(), std::io::Error> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let from_wide: Vec<u16> = from
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let to_wide: Vec<u16> = to
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: both buffers are owned, NUL-terminated UTF-16 paths and remain
    // alive for the duration of the call.
    let ok = unsafe {
        MoveFileExW(
            from_wide.as_ptr(),
            to_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn replace_atomically(from: &Path, to: &Path) -> Result<(), std::io::Error> {
    std::fs::rename(from, to)
}

pub fn save_policy(data_dir: &Path, policy: &NodePolicy) -> Result<(), PolicyError> {
    std::fs::create_dir_all(data_dir)?;
    let path = policy_path(data_dir);
    let raw = serde_json::to_string_pretty(policy)?;
    let (temp, mut f) = create_policy_temp(data_dir)?;

    let write_result = (|| -> Result<(), std::io::Error> {
        f.write_all(raw.as_bytes())?;
        f.sync_all()?;
        drop(f);
        replace_atomically(&temp, &path)?;
        #[cfg(unix)]
        std::fs::File::open(data_dir)?.sync_all()?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    write_result?;
    Ok(())
}

/// Safe status snapshot for ash (never includes keys or packed envelopes).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BridgeStatusSnapshot {
    pub bridge: bool,
    pub store: bool,
    pub relay: bool,
    pub endpoint: bool,
    pub auto_policy: bool,
    pub transports: Vec<String>,
    pub forward_queue_pending: usize,
    pub forward_queue_total: usize,
    pub capabilities: Vec<String>,
}

impl BridgeStatusSnapshot {
    pub fn from_policy(
        policy: &NodePolicy,
        transports: &[&str],
        pending: usize,
        total: usize,
    ) -> Self {
        let mut caps = Vec::new();
        if transports.iter().any(|t| *t == "ble" || *t == "mock_ble") {
            caps.push("ble".into());
        }
        // A local TCP/LAN listener is not proof of Internet reachability.
        // Advertise the Internet capability only for a real Internet adapter.
        if transports.contains(&"internet") {
            caps.push("internet".into());
        }
        if policy.relay {
            caps.push("relay".into());
        }
        if policy.store {
            caps.push("store".into());
        }
        if policy.bridge {
            caps.push("bridge".into());
        }
        Self {
            bridge: policy.bridge,
            store: policy.store,
            relay: policy.relay,
            endpoint: policy.endpoint,
            auto_policy: policy.auto_policy,
            transports: transports.iter().map(|s| (*s).to_string()).collect(),
            forward_queue_pending: pending,
            forward_queue_total: total,
            capabilities: caps,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn roundtrip_policy() {
        let dir = tempdir().unwrap();
        let p = NodePolicy {
            bridge: false,
            auto_policy: false,
            ..Default::default()
        };
        save_policy(dir.path(), &p).unwrap();
        let loaded = load_policy(dir.path());
        assert!(!loaded.bridge);
        assert!(!loaded.auto_policy);
    }

    #[test]
    fn malformed_existing_policy_fails_closed() {
        let dir = tempdir().unwrap();
        std::fs::write(policy_path(dir.path()), b"{not-json").unwrap();
        assert_eq!(load_policy(dir.path()), NodePolicy::fail_closed());
    }

    #[test]
    fn missing_policy_keeps_first_run_defaults() {
        let dir = tempdir().unwrap();
        assert_eq!(load_policy(dir.path()), NodePolicy::default());
    }

    #[test]
    fn replacement_does_not_leave_partial_or_temp_policy() {
        let dir = tempdir().unwrap();
        save_policy(dir.path(), &NodePolicy::default()).unwrap();
        let replacement = NodePolicy::fail_closed();
        save_policy(dir.path(), &replacement).unwrap();
        assert_eq!(load_policy(dir.path()), replacement);
        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".node_policy.json.tmp-")
            })
            .collect();
        assert!(leftovers.is_empty());
    }
}
