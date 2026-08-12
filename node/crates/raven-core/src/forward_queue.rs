//! Persistent opaque forward queue (Bridge V1 store-carry-bridge).
//!
//! Holds packed RavenEnvelopeV1 bytes only — never plaintext / ratchet keys.
//! Survives raven-node restart; expires by envelope TTL / row expires_at_ms.

use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use thiserror::Error;

use crate::transport::TransportKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ForwardState {
    Queued = 0,
    InFlight = 1,
    Forwarded = 2,
    Expired = 3,
    Failed = 4,
}

impl ForwardState {
    fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::InFlight,
            2 => Self::Forwarded,
            3 => Self::Expired,
            4 => Self::Failed,
            _ => Self::Queued,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ForwardItem {
    pub message_id: [u8; 16],
    pub packed_envelope: Vec<u8>,
    pub ingress: TransportKind,
    pub egress: TransportKind,
    pub state: ForwardState,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub previous_hop: String,
}

#[derive(Error, Debug)]
pub enum ForwardQueueError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("bad message_id")]
    BadId,
    #[error("queue full (limit {0})")]
    QueueFull(usize),
    #[error("envelope too large ({0} bytes)")]
    TooLarge(usize),
}

/// Default V1 limits (never flood).
pub const MAX_FORWARD_QUEUE: usize = 512;
pub const MAX_ENVELOPE_BYTES: usize = 1_048_576;
/// Cap pending custody per previous_hop (opaque peer key — not MAC/IP identity).
pub const MAX_PER_PEER_PENDING: usize = 64;
/// Max new enqueues accepted from one peer inside `PEER_RATE_WINDOW_MS`.
pub const MAX_PER_PEER_ENQUEUES_PER_WINDOW: usize = 30;
pub const PEER_RATE_WINDOW_MS: u64 = 60_000;
/// Soft per-peer byte budget inside the same window (text envelopes ≪ this).
pub const MAX_PER_PEER_BYTES_PER_WINDOW: u64 = 256_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerRateDecision {
    Allow,
    PeerQueueFull,
    RateLimited,
}

pub struct ForwardQueue {
    conn: Connection,
    max_items: usize,
    max_bytes: usize,
    max_per_peer_pending: usize,
    max_per_peer_enqueues: usize,
    max_per_peer_bytes: u64,
    peer_rate_window_ms: u64,
}

impl ForwardQueue {
    pub fn open(path: &Path) -> Result<Self, ForwardQueueError> {
        Self::open_with_limits(path, MAX_FORWARD_QUEUE, MAX_ENVELOPE_BYTES)
    }

    pub fn open_with_limits(
        path: &Path,
        max_items: usize,
        max_bytes: usize,
    ) -> Result<Self, ForwardQueueError> {
        Self::open_with_peer_limits(
            path,
            max_items,
            max_bytes,
            MAX_PER_PEER_PENDING,
            MAX_PER_PEER_ENQUEUES_PER_WINDOW,
            MAX_PER_PEER_BYTES_PER_WINDOW,
            PEER_RATE_WINDOW_MS,
        )
    }

    pub fn open_with_peer_limits(
        path: &Path,
        max_items: usize,
        max_bytes: usize,
        max_per_peer_pending: usize,
        max_per_peer_enqueues: usize,
        max_per_peer_bytes: u64,
        peer_rate_window_ms: u64,
    ) -> Result<Self, ForwardQueueError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS forward_queue (
               message_id BLOB PRIMARY KEY NOT NULL,
               packed BLOB NOT NULL,
               ingress TEXT NOT NULL,
               egress TEXT NOT NULL,
               state INTEGER NOT NULL,
               created_at_ms INTEGER NOT NULL,
               expires_at_ms INTEGER NOT NULL,
               previous_hop TEXT NOT NULL DEFAULT ''
             );
             CREATE TABLE IF NOT EXISTS bridge_seen (
               message_id BLOB PRIMARY KEY NOT NULL,
               seen_at_ms INTEGER NOT NULL,
               ingress TEXT NOT NULL,
               previous_hop TEXT NOT NULL DEFAULT ''
             );
             CREATE TABLE IF NOT EXISTS bridge_peer_rate (
               peer_key TEXT NOT NULL,
               window_start_ms INTEGER NOT NULL,
               enqueue_count INTEGER NOT NULL,
               byte_count INTEGER NOT NULL,
               PRIMARY KEY (peer_key, window_start_ms)
             );",
        )?;
        Ok(Self {
            conn,
            max_items,
            max_bytes,
            max_per_peer_pending,
            max_per_peer_enqueues,
            max_per_peer_bytes,
            peer_rate_window_ms,
        })
    }

    pub fn count_pending_for_peer(&self, previous_hop: &str) -> Result<usize, ForwardQueueError> {
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM forward_queue
             WHERE state IN (0, 1) AND previous_hop = ?1",
            params![previous_hop],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    /// Sliding-window per-peer abuse check. Records the attempt only when Allow.
    pub fn check_peer_rate(
        &self,
        previous_hop: &str,
        now_ms: u64,
        envelope_bytes: usize,
    ) -> Result<PeerRateDecision, ForwardQueueError> {
        let peer = previous_hop;
        if self.count_pending_for_peer(peer)? >= self.max_per_peer_pending {
            return Ok(PeerRateDecision::PeerQueueFull);
        }
        let window = self.peer_rate_window_ms.max(1);
        let window_start = (now_ms / window) * window;
        // Drop older windows (keep DB small).
        self.conn.execute(
            "DELETE FROM bridge_peer_rate WHERE window_start_ms < ?1",
            params![window_start.saturating_sub(window * 2) as i64],
        )?;
        let row: Option<(i64, i64)> = self
            .conn
            .query_row(
                "SELECT enqueue_count, byte_count FROM bridge_peer_rate
                 WHERE peer_key = ?1 AND window_start_ms = ?2",
                params![peer, window_start as i64],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (count, bytes) = row.unwrap_or((0, 0));
        if count as usize >= self.max_per_peer_enqueues
            || (bytes as u64).saturating_add(envelope_bytes as u64) > self.max_per_peer_bytes
        {
            return Ok(PeerRateDecision::RateLimited);
        }
        self.conn.execute(
            "INSERT INTO bridge_peer_rate (peer_key, window_start_ms, enqueue_count, byte_count)
             VALUES (?1, ?2, 1, ?3)
             ON CONFLICT(peer_key, window_start_ms) DO UPDATE SET
               enqueue_count = enqueue_count + 1,
               byte_count = byte_count + excluded.byte_count",
            params![peer, window_start as i64, envelope_bytes as i64],
        )?;
        Ok(PeerRateDecision::Allow)
    }

    pub fn count_pending(&self) -> Result<usize, ForwardQueueError> {
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM forward_queue WHERE state IN (0, 1)",
            [],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    pub fn count_all(&self) -> Result<usize, ForwardQueueError> {
        let n: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM forward_queue", [], |r| r.get(0))?;
        Ok(n as usize)
    }

    pub fn enqueue(&self, item: &ForwardItem) -> Result<(), ForwardQueueError> {
        if item.message_id.len() != 16 {
            return Err(ForwardQueueError::BadId);
        }
        if item.packed_envelope.len() > self.max_bytes {
            return Err(ForwardQueueError::TooLarge(item.packed_envelope.len()));
        }
        let pending = self.count_pending()?;
        // Allow replace of same id; block growth beyond limit for new ids.
        let exists: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM forward_queue WHERE message_id = ?1",
                params![item.message_id.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() && pending >= self.max_items {
            return Err(ForwardQueueError::QueueFull(self.max_items));
        }
        // SQLite INTEGER is signed; clamp so u64::MAX does not store as -1.
        let expires_i64 = item.expires_at_ms.min(i64::MAX as u64) as i64;
        let created_i64 = item.created_at_ms.min(i64::MAX as u64) as i64;
        self.conn.execute(
            "INSERT OR REPLACE INTO forward_queue
             (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                item.message_id.as_slice(),
                item.packed_envelope,
                item.ingress.as_str(),
                item.egress.as_str(),
                item.state as u8,
                created_i64,
                expires_i64,
                item.previous_hop,
            ],
        )?;
        Ok(())
    }

    pub fn mark_state(
        &self,
        message_id: &[u8; 16],
        state: ForwardState,
    ) -> Result<(), ForwardQueueError> {
        self.conn.execute(
            "UPDATE forward_queue SET state = ?1 WHERE message_id = ?2",
            params![state as u8, message_id.as_slice()],
        )?;
        Ok(())
    }

    /// Pending (Queued/InFlight) that are not expired.
    pub fn pending_ready(&self, now_ms: u64) -> Result<Vec<ForwardItem>, ForwardQueueError> {
        self.expire_stale(now_ms)?;
        let mut stmt = self.conn.prepare(
            "SELECT message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_queue
             WHERE state IN (0, 1) AND expires_at_ms >= ?1
             ORDER BY created_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![now_ms as i64], row_to_item)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn expire_stale(&self, now_ms: u64) -> Result<usize, ForwardQueueError> {
        let n = self.conn.execute(
            "UPDATE forward_queue SET state = ?1
             WHERE state IN (0, 1) AND expires_at_ms < ?2",
            params![ForwardState::Expired as u8, now_ms as i64],
        )?;
        Ok(n)
    }

    pub fn get(&self, message_id: &[u8; 16]) -> Result<Option<ForwardItem>, ForwardQueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_queue WHERE message_id = ?1",
        )?;
        let row = stmt
            .query_row(params![message_id.as_slice()], row_to_item)
            .optional()?;
        Ok(row)
    }

    /// Dedup: true if already seen (duplicate). Records first sight.
    pub fn seen_check_and_insert(
        &self,
        message_id: &[u8; 16],
        now_ms: u64,
        ingress: TransportKind,
        previous_hop: &str,
    ) -> Result<bool, ForwardQueueError> {
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM bridge_seen WHERE message_id = ?1",
                params![message_id.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        if existing.is_some() {
            return Ok(true);
        }
        self.conn.execute(
            "INSERT INTO bridge_seen (message_id, seen_at_ms, ingress, previous_hop)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                message_id.as_slice(),
                now_ms as i64,
                ingress.as_str(),
                previous_hop
            ],
        )?;
        Ok(false)
    }

    pub fn was_seen(&self, message_id: &[u8; 16]) -> Result<bool, ForwardQueueError> {
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM bridge_seen WHERE message_id = ?1",
                params![message_id.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        Ok(existing.is_some())
    }
}

fn parse_transport(s: &str) -> TransportKind {
    match s {
        "ble" => TransportKind::Ble,
        "lan" => TransportKind::Lan,
        "internet" => TransportKind::Internet,
        _ => TransportKind::MockBle,
    }
}

fn row_to_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<ForwardItem> {
    let id: Vec<u8> = r.get(0)?;
    let mut mid = [0u8; 16];
    if id.len() == 16 {
        mid.copy_from_slice(&id);
    }
    let ingress_s: String = r.get(2)?;
    let egress_s: String = r.get(3)?;
    Ok(ForwardItem {
        message_id: mid,
        packed_envelope: r.get(1)?,
        ingress: parse_transport(&ingress_s),
        egress: parse_transport(&egress_s),
        state: ForwardState::from_u8(r.get::<_, u8>(4)?),
        created_at_ms: r.get::<_, i64>(5)? as u64,
        expires_at_ms: r.get::<_, i64>(6)? as u64,
        previous_hop: r.get(7)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn persist_and_expire() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        let mid = [3u8; 16];
        {
            let q = ForwardQueue::open(&path).unwrap();
            q.enqueue(&ForwardItem {
                message_id: mid,
                packed_envelope: vec![1, 2, 3],
                ingress: TransportKind::MockBle,
                egress: TransportKind::Lan,
                state: ForwardState::Queued,
                created_at_ms: 1,
                expires_at_ms: 100,
                previous_hop: "peer-a".into(),
            })
            .unwrap();
            assert_eq!(q.count_pending().unwrap(), 1);
        }
        let q = ForwardQueue::open(&path).unwrap();
        assert_eq!(q.pending_ready(50).unwrap().len(), 1);
        assert!(q.pending_ready(200).unwrap().is_empty());
        let item = q.get(&mid).unwrap().unwrap();
        assert_eq!(item.state, ForwardState::Expired);
    }

    #[test]
    fn dedup_seen() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let mid = [9u8; 16];
        assert!(!q
            .seen_check_and_insert(&mid, 1, TransportKind::Lan, "h1")
            .unwrap());
        assert!(q
            .seen_check_and_insert(&mid, 2, TransportKind::MockBle, "h2")
            .unwrap());
    }

    #[test]
    fn per_peer_rate_and_pending_caps() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open_with_peer_limits(
            &dir.path().join("fwd.sqlite"),
            512,
            MAX_ENVELOPE_BYTES,
            2,    // max pending per peer
            3,    // max enqueues / window
            10_000,
            60_000,
        )
        .unwrap();
        let now = 1_700_000_000_000u64;
        assert_eq!(
            q.check_peer_rate("peer-a", now, 100).unwrap(),
            PeerRateDecision::Allow
        );
        assert_eq!(
            q.check_peer_rate("peer-a", now + 1, 100).unwrap(),
            PeerRateDecision::Allow
        );
        assert_eq!(
            q.check_peer_rate("peer-a", now + 2, 100).unwrap(),
            PeerRateDecision::Allow
        );
        assert_eq!(
            q.check_peer_rate("peer-a", now + 3, 100).unwrap(),
            PeerRateDecision::RateLimited
        );
        // Other peer unaffected.
        assert_eq!(
            q.check_peer_rate("peer-b", now, 100).unwrap(),
            PeerRateDecision::Allow
        );

        for i in 0u8..2 {
            q.enqueue(&ForwardItem {
                message_id: [i; 16],
                packed_envelope: vec![1, 2, 3],
                ingress: TransportKind::Lan,
                egress: TransportKind::MockBle,
                state: ForwardState::Queued,
                created_at_ms: now,
                expires_at_ms: now + 60_000,
                previous_hop: "peer-c".into(),
            })
            .unwrap();
        }
        assert_eq!(q.count_pending_for_peer("peer-c").unwrap(), 2);
        // Fresh queue with pending-only check path via check_peer_rate.
        let q2 = ForwardQueue::open_with_peer_limits(
            &dir.path().join("fwd2.sqlite"),
            512,
            MAX_ENVELOPE_BYTES,
            1,
            100,
            1_000_000,
            60_000,
        )
        .unwrap();
        q2.enqueue(&ForwardItem {
            message_id: [7u8; 16],
            packed_envelope: vec![9],
            ingress: TransportKind::Lan,
            egress: TransportKind::MockBle,
            state: ForwardState::Queued,
            created_at_ms: now,
            expires_at_ms: now + 60_000,
            previous_hop: "full".into(),
        })
        .unwrap();
        assert_eq!(
            q2.check_peer_rate("full", now, 10).unwrap(),
            PeerRateDecision::PeerQueueFull
        );
    }
}
