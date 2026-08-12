//! Bootstrap peer configuration (§30).
//!
//! Raven-provided defaults are optional and empty by default — a user can
//! start with only manually supplied multiaddrs / host:port peers. Bootstrap
//! peers are untrusted relays for dial hints only (no identity authority,
//! no plaintext).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Bootstrap / dial-hint configuration (no secrets).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BootstrapConfig {
    /// When false, ignore `raven_defaults` entirely.
    #[serde(default = "default_true")]
    pub use_raven_defaults: bool,
    /// Optional Raven-shipped multiaddrs (may be empty — not required).
    #[serde(default)]
    pub raven_defaults: Vec<String>,
    /// User-supplied bootstrap multiaddrs (community or self-hosted).
    #[serde(default)]
    pub custom: Vec<String>,
    /// Explicit manual peers for direct dial (proves no Raven-owned dependency).
    #[serde(default)]
    pub manual_peers: Vec<String>,
}

fn default_true() -> bool {
    true
}

impl Default for BootstrapConfig {
    fn default() -> Self {
        Self {
            // Defaults list is empty — serverless V1 does not require Raven-owned nodes.
            use_raven_defaults: true,
            raven_defaults: Vec::new(),
            custom: Vec::new(),
            manual_peers: Vec::new(),
        }
    }
}

impl BootstrapConfig {
    /// Effective dial targets: manual + custom + (optional empty Raven defaults).
    pub fn effective_peers(&self) -> Vec<String> {
        let mut out = Vec::new();
        for p in &self.manual_peers {
            push_unique(&mut out, p);
        }
        for p in &self.custom {
            push_unique(&mut out, p);
        }
        if self.use_raven_defaults {
            for p in &self.raven_defaults {
                push_unique(&mut out, p);
            }
        }
        out
    }

    /// True when startup can proceed without any Raven-owned bootstrap entry.
    pub fn manual_peer_only_ok(&self) -> bool {
        !self.manual_peers.is_empty()
            && (self.raven_defaults.is_empty() || !self.use_raven_defaults)
    }

    pub fn add_custom(&mut self, multiaddr: impl Into<String>) {
        let s = multiaddr.into();
        if !self.custom.iter().any(|x| x == &s) {
            self.custom.push(s);
        }
    }

    pub fn remove_raven_defaults(&mut self) {
        self.use_raven_defaults = false;
        self.raven_defaults.clear();
    }
}

fn push_unique(out: &mut Vec<String>, p: &str) {
    if !out.iter().any(|x| x == p) {
        out.push(p.to_string());
    }
}

#[derive(Error, Debug)]
pub enum BootstrapError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn bootstrap_path(data_dir: &Path) -> PathBuf {
    data_dir.join("bootstrap.json")
}

pub fn load_bootstrap(data_dir: &Path) -> BootstrapConfig {
    let path = bootstrap_path(data_dir);
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return BootstrapConfig::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_bootstrap(data_dir: &Path, cfg: &BootstrapConfig) -> Result<(), BootstrapError> {
    std::fs::create_dir_all(data_dir)?;
    let path = bootstrap_path(data_dir);
    let raw = serde_json::to_string_pretty(cfg)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn manual_peer_only_without_raven() {
        let mut cfg = BootstrapConfig::default();
        assert!(cfg.raven_defaults.is_empty());
        cfg.manual_peers.push("/ip4/127.0.0.1/tcp/4001".into());
        assert!(cfg.manual_peer_only_ok());
        assert_eq!(cfg.effective_peers().len(), 1);
    }

    #[test]
    fn disable_raven_defaults() {
        let mut cfg = BootstrapConfig {
            use_raven_defaults: true,
            raven_defaults: vec!["/dnsaddr/bootstrap.example".into()],
            custom: vec![],
            manual_peers: vec!["/ip4/10.0.0.1/tcp/9".into()],
        };
        assert!(!cfg.manual_peer_only_ok());
        cfg.remove_raven_defaults();
        assert!(cfg.manual_peer_only_ok());
        assert_eq!(cfg.effective_peers(), vec!["/ip4/10.0.0.1/tcp/9".to_string()]);
    }

    #[test]
    fn roundtrip_file() {
        let dir = tempdir().unwrap();
        let mut cfg = BootstrapConfig::default();
        cfg.add_custom("/ip4/192.0.2.1/tcp/4001");
        cfg.manual_peers.push("127.0.0.1:9000".into());
        save_bootstrap(dir.path(), &cfg).unwrap();
        let loaded = load_bootstrap(dir.path());
        assert_eq!(loaded.custom.len(), 1);
        assert_eq!(loaded.manual_peers.len(), 1);
    }
}
