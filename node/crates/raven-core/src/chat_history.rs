//! Local chat history metadata (petname-first). Never stores private keys.
//! Sanitized previews only — operator may clear with `/clear-local-history`.

use crate::sanitize::sanitize_terminal_text;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
pub struct ChatHistory {
    pub entries: Vec<ChatHistoryEntry>,
}

const MAX_ENTRIES: usize = 2_000;

pub fn history_path(data_dir: &Path) -> PathBuf {
    data_dir.join("chat_history.json")
}

pub fn blocked_path(data_dir: &Path) -> PathBuf {
    data_dir.join("blocked_pubs.json")
}

impl ChatHistory {
    pub fn load(data_dir: &Path) -> Self {
        let path = history_path(data_dir);
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&raw).unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), String> {
        std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
        let path = history_path(data_dir);
        let raw = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&path)
                .map_err(|e| e.to_string())?;
            f.write_all(raw.as_bytes()).map_err(|e| e.to_string())?;
        }
        #[cfg(not(unix))]
        {
            std::fs::write(&path, raw).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub fn append(&mut self, mut entry: ChatHistoryEntry) {
        entry.peer_petname = sanitize_terminal_text(&entry.peer_petname);
        entry.peer_tag = sanitize_terminal_text(&entry.peer_tag);
        entry.preview = sanitize_terminal_text(&entry.preview);
        if entry.preview.chars().count() > 120 {
            entry.preview = entry.preview.chars().take(120).collect();
        }
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

    #[test]
    fn history_roundtrip_sanitizes() {
        let dir = tempdir().unwrap();
        let mut h = ChatHistory::default();
        h.append(ChatHistoryEntry {
            message_id_hex: "aa".into(),
            direction: "out".into(),
            peer_petname: "Alice\x1b[31m".into(),
            peer_tag: "alice".into(),
            peer_pub_hex: "ab".into(),
            created_at_ms: 1,
            delivery: "queued".into(),
            preview: "hi\nthere".into(),
        });
        h.save(dir.path()).unwrap();
        let loaded = ChatHistory::load(dir.path());
        assert_eq!(loaded.entries.len(), 1);
        assert!(!loaded.entries[0].peer_petname.contains('\x1b'));
    }

    #[test]
    fn block_list() {
        let dir = tempdir().unwrap();
        let mut b = BlockList::default();
        b.block("AABB");
        assert!(b.is_blocked("aabb"));
        b.save(dir.path()).unwrap();
        assert!(BlockList::load(dir.path()).is_blocked("aabb"));
    }
}
