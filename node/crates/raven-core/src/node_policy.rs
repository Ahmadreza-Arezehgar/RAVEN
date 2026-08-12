//! Local node policy config (ash writes; raven-node reads). No secrets.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
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
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return NodePolicy::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_policy(data_dir: &Path, policy: &NodePolicy) -> Result<(), PolicyError> {
    std::fs::create_dir_all(data_dir)?;
    let path = policy_path(data_dir);
    let raw = serde_json::to_string_pretty(policy)?;
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)?;
        f.write_all(raw.as_bytes())?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&path, raw)?;
    }
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
        if transports
            .iter()
            .any(|t| *t == "lan" || *t == "internet")
        {
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
        let mut p = NodePolicy::default();
        p.bridge = false;
        p.auto_policy = false;
        save_policy(dir.path(), &p).unwrap();
        let loaded = load_policy(dir.path());
        assert!(!loaded.bridge);
        assert!(!loaded.auto_policy);
    }
}
