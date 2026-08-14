//! Persistent opaque forward queue (Bridge V1 store-carry-bridge).
//!
//! Holds packed RavenEnvelopeV1 bytes only — never plaintext / ratchet keys.
//! Survives raven-node restart; expires by envelope TTL / row expires_at_ms.

use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use thiserror::Error;

use crate::bridge::authenticated_object_digest;
use crate::envelope::Envelope;
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
    /// Immutable relay-object identity persisted as the V2 primary key.
    pub object_digest: [u8; 32],
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
    #[error("object_digest does not match packed envelope")]
    BadObjectDigest,
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
/// Relay replay cache is deliberately bounded; unauthenticated peers must not
/// be able to grow a durable table without limit.
pub const MAX_RELAY_SEEN_OBJECTS: usize = 4_096;
pub const RELAY_SEEN_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

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
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA busy_timeout=10000;
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
             CREATE TABLE IF NOT EXISTS forward_objects_v2 (
               object_digest BLOB PRIMARY KEY NOT NULL,
               message_id BLOB NOT NULL,
               packed BLOB NOT NULL,
               ingress TEXT NOT NULL,
               egress TEXT NOT NULL,
               state INTEGER NOT NULL,
               created_at_ms INTEGER NOT NULL,
               expires_at_ms INTEGER NOT NULL,
               previous_hop TEXT NOT NULL DEFAULT ''
             );
             CREATE INDEX IF NOT EXISTS idx_forward_objects_v2_message_id
               ON forward_objects_v2(message_id);
             CREATE TABLE IF NOT EXISTS bridge_seen_objects_v2 (
               object_digest BLOB PRIMARY KEY NOT NULL,
               seen_at_ms INTEGER NOT NULL,
               ingress TEXT NOT NULL,
               previous_hop TEXT NOT NULL DEFAULT ''
             );
             CREATE INDEX IF NOT EXISTS idx_bridge_seen_objects_v2_time
               ON bridge_seen_objects_v2(seen_at_ms);
             CREATE TABLE IF NOT EXISTS bridge_peer_rate (
               peer_key TEXT NOT NULL,
               window_start_ms INTEGER NOT NULL,
               enqueue_count INTEGER NOT NULL,
               byte_count INTEGER NOT NULL,
               PRIMARY KEY (peer_key, window_start_ms)
             );",
        )?;
        migrate_legacy_forward_rows(&conn)?;
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
            "SELECT COUNT(*) FROM forward_objects_v2
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
            "SELECT COUNT(*) FROM forward_objects_v2 WHERE state IN (0, 1)",
            [],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    pub fn count_all(&self) -> Result<usize, ForwardQueueError> {
        let n: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM forward_objects_v2", [], |r| r.get(0))?;
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
        let env = Envelope::unpack(&item.packed_envelope).ok_or(ForwardQueueError::BadId)?;
        if env.message_id != item.message_id {
            return Err(ForwardQueueError::BadId);
        }
        let object_digest = authenticated_object_digest(&env);
        if item.object_digest != object_digest {
            return Err(ForwardQueueError::BadObjectDigest);
        }
        // Exact immutable objects are idempotent. Different objects carrying
        // the same public message_id occupy separate bounded rows, preventing
        // a forged first arrival from poisoning a later valid object.
        let exists: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM forward_objects_v2 WHERE object_digest = ?1",
                params![object_digest.as_slice()],
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
            "INSERT OR REPLACE INTO forward_objects_v2
             (object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                object_digest.as_slice(),
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

    pub fn mark_object_state(
        &self,
        object_digest: &[u8; 32],
        state: ForwardState,
    ) -> Result<(), ForwardQueueError> {
        self.conn.execute(
            "UPDATE forward_objects_v2 SET state = ?1 WHERE object_digest = ?2",
            params![state as u8, object_digest.as_slice()],
        )?;
        Ok(())
    }

    /// Pending (Queued/InFlight) that are not expired.
    pub fn pending_ready(&self, now_ms: u64) -> Result<Vec<ForwardItem>, ForwardQueueError> {
        self.expire_stale(now_ms)?;
        let mut stmt = self.conn.prepare(
            "SELECT object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_objects_v2
             WHERE state IN (0, 1) AND expires_at_ms >= ?1
             ORDER BY created_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![now_ms as i64], row_to_v2_item)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn expire_stale(&self, now_ms: u64) -> Result<usize, ForwardQueueError> {
        let n = self.conn.execute(
            "UPDATE forward_objects_v2 SET state = ?1
             WHERE state IN (0, 1) AND expires_at_ms < ?2",
            params![ForwardState::Expired as u8, now_ms as i64],
        )?;
        Ok(n)
    }

    pub fn get(&self, message_id: &[u8; 16]) -> Result<Option<ForwardItem>, ForwardQueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_objects_v2 WHERE message_id = ?1
             ORDER BY created_at_ms ASC, object_digest ASC LIMIT 1",
        )?;
        let row = stmt
            .query_row(params![message_id.as_slice()], row_to_v2_item)
            .optional()?;
        Ok(row)
    }

    pub fn get_object(
        &self,
        object_digest: &[u8; 32],
    ) -> Result<Option<ForwardItem>, ForwardQueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_objects_v2 WHERE object_digest = ?1",
        )?;
        let row = stmt
            .query_row(params![object_digest.as_slice()], row_to_v2_item)
            .optional()?;
        Ok(row)
    }

    /// Read-only relay dedup lookup. Callers MUST perform this before resource
    /// admission but insert only after the object was successfully admitted.
    pub fn object_was_seen(&self, object_digest: &[u8; 32]) -> Result<bool, ForwardQueueError> {
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM bridge_seen_objects_v2 WHERE object_digest = ?1",
                params![object_digest.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        Ok(existing.is_some())
    }

    /// Record an already-admitted immutable relay object. The table is pruned
    /// by age and a hard row cap before every insert.
    pub fn mark_object_seen(
        &self,
        object_digest: &[u8; 32],
        now_ms: u64,
        ingress: TransportKind,
        previous_hop: &str,
    ) -> Result<(), ForwardQueueError> {
        self.prune_seen_objects(now_ms)?;
        self.conn.execute(
            "INSERT OR IGNORE INTO bridge_seen_objects_v2
             (object_digest, seen_at_ms, ingress, previous_hop)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                object_digest.as_slice(),
                now_ms as i64,
                ingress.as_str(),
                previous_hop
            ],
        )?;
        Ok(())
    }

    pub fn prune_seen_objects(&self, now_ms: u64) -> Result<(), ForwardQueueError> {
        let cutoff = now_ms
            .saturating_sub(RELAY_SEEN_TTL_MS)
            .min(i64::MAX as u64) as i64;
        self.conn.execute(
            "DELETE FROM bridge_seen_objects_v2 WHERE seen_at_ms < ?1",
            params![cutoff],
        )?;
        self.conn.execute(
            "DELETE FROM bridge_seen_objects_v2
             WHERE object_digest IN (
               SELECT object_digest FROM bridge_seen_objects_v2
               ORDER BY seen_at_ms DESC, object_digest DESC
               LIMIT -1 OFFSET ?1
             )",
            params![MAX_RELAY_SEEN_OBJECTS as i64],
        )?;
        Ok(())
    }
}

/// One-time, idempotent migration from the original message-id-keyed queue.
/// Keeping every distinct immutable object in V2 removes the attacker-chosen
/// message-ID overwrite/poisoning primitive while preserving queued custody.
fn migrate_legacy_forward_rows(conn: &Connection) -> Result<(), ForwardQueueError> {
    let legacy = {
        let mut stmt = conn.prepare(
            "SELECT message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_queue",
        )?;
        let rows = stmt.query_map([], row_to_legacy_item)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        out
    };
    for item in legacy {
        let Some(env) = Envelope::unpack(&item.packed_envelope) else {
            continue;
        };
        if env.message_id != item.message_id {
            continue;
        }
        let digest = authenticated_object_digest(&env);
        conn.execute(
            "INSERT OR IGNORE INTO forward_objects_v2
             (object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                digest.as_slice(),
                item.message_id.as_slice(),
                item.packed_envelope,
                item.ingress.as_str(),
                item.egress.as_str(),
                item.state as u8,
                item.created_at_ms.min(i64::MAX as u64) as i64,
                item.expires_at_ms.min(i64::MAX as u64) as i64,
                item.previous_hop,
            ],
        )?;
    }
    Ok(())
}

fn parse_transport(s: &str) -> TransportKind {
    match s {
        "ble" => TransportKind::Ble,
        "lan" => TransportKind::Lan,
        "internet" => TransportKind::Internet,
        _ => TransportKind::MockBle,
    }
}

fn row_to_legacy_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<ForwardItem> {
    let id: Vec<u8> = r.get(0)?;
    let mut mid = [0u8; 16];
    if id.len() == 16 {
        mid.copy_from_slice(&id);
    }
    let packed_envelope: Vec<u8> = r.get(1)?;
    let object_digest = Envelope::unpack(&packed_envelope)
        .map(|env| authenticated_object_digest(&env))
        .unwrap_or([0u8; 32]);
    let ingress_s: String = r.get(2)?;
    let egress_s: String = r.get(3)?;
    Ok(ForwardItem {
        object_digest,
        message_id: mid,
        packed_envelope,
        ingress: parse_transport(&ingress_s),
        egress: parse_transport(&egress_s),
        state: ForwardState::from_u8(r.get::<_, u8>(4)?),
        created_at_ms: r.get::<_, i64>(5)? as u64,
        expires_at_ms: r.get::<_, i64>(6)? as u64,
        previous_hop: r.get(7)?,
    })
}

fn row_to_v2_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<ForwardItem> {
    let digest: Vec<u8> = r.get(0)?;
    let mut object_digest = [0u8; 32];
    if digest.len() == object_digest.len() {
        object_digest.copy_from_slice(&digest);
    }
    let id: Vec<u8> = r.get(1)?;
    let mut message_id = [0u8; 16];
    if id.len() == message_id.len() {
        message_id.copy_from_slice(&id);
    }
    let ingress_s: String = r.get(3)?;
    let egress_s: String = r.get(4)?;
    Ok(ForwardItem {
        object_digest,
        message_id,
        packed_envelope: r.get(2)?,
        ingress: parse_transport(&ingress_s),
        egress: parse_transport(&egress_s),
        state: ForwardState::from_u8(r.get::<_, u8>(5)?),
        created_at_ms: r.get::<_, i64>(6)? as u64,
        expires_at_ms: r.get::<_, i64>(7)? as u64,
        previous_hop: r.get(8)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::{EnvType, Envelope};
    use crate::identity::Identity;
    use sha2::Digest;
    use tempfile::tempdir;

    fn packed_with_body(mid: [u8; 16], body: &[u8]) -> Vec<u8> {
        let identity = Identity::from_seed(&[mid[0].wrapping_add(1); 32]);
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: mid,
            routing_tag: [1u8; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at: 10_000,
            hop_limit: 4,
            replication_budget: 2,
            anti_replay_nonce: [2u8; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: body.to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&identity);
        env.pack()
    }

    fn packed(mid: [u8; 16]) -> Vec<u8> {
        packed_with_body(mid, &[mid[0], 3, 4])
    }

    fn item(mid: [u8; 16], packed_envelope: Vec<u8>) -> ForwardItem {
        let env = Envelope::unpack(&packed_envelope).unwrap();
        ForwardItem {
            object_digest: authenticated_object_digest(&env),
            message_id: mid,
            packed_envelope,
            ingress: TransportKind::MockBle,
            egress: TransportKind::Lan,
            state: ForwardState::Queued,
            created_at_ms: 1,
            expires_at_ms: 100,
            previous_hop: "peer-a".into(),
        }
    }

    #[test]
    fn persist_and_expire() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        let mid = [3u8; 16];
        {
            let q = ForwardQueue::open(&path).unwrap();
            q.enqueue(&item(mid, packed(mid))).unwrap();
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
        let env = Envelope::unpack(&packed(mid)).unwrap();
        let digest = authenticated_object_digest(&env);
        assert!(!q.object_was_seen(&digest).unwrap());
        q.mark_object_seen(&digest, 1, TransportKind::Lan, "h1")
            .unwrap();
        assert!(q.object_was_seen(&digest).unwrap());
    }

    #[test]
    fn per_peer_rate_and_pending_caps() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open_with_peer_limits(
            &dir.path().join("fwd.sqlite"),
            512,
            MAX_ENVELOPE_BYTES,
            2, // max pending per peer
            3, // max enqueues / window
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
            let mid = [i; 16];
            let packed_envelope = packed(mid);
            let env = Envelope::unpack(&packed_envelope).unwrap();
            q.enqueue(&ForwardItem {
                object_digest: authenticated_object_digest(&env),
                message_id: mid,
                packed_envelope,
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
        let mid = [7u8; 16];
        let packed_envelope = packed(mid);
        let env = Envelope::unpack(&packed_envelope).unwrap();
        q2.enqueue(&ForwardItem {
            object_digest: authenticated_object_digest(&env),
            message_id: mid,
            packed_envelope,
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

    #[test]
    fn same_message_id_objects_transition_independently() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let mid = [0x44; 16];
        let first = item(mid, packed_with_body(mid, b"first object"));
        let mut second = item(mid, packed_with_body(mid, b"second object"));
        second.created_at_ms = 2;
        let first_digest = first.object_digest;
        let second_digest = second.object_digest;
        assert_ne!(first_digest, second_digest);

        q.enqueue(&first).unwrap();
        q.enqueue(&second).unwrap();
        q.mark_object_state(&first_digest, ForwardState::Forwarded)
            .unwrap();

        assert_eq!(
            q.get_object(&first_digest).unwrap().unwrap().state,
            ForwardState::Forwarded
        );
        assert_eq!(
            q.get_object(&second_digest).unwrap().unwrap().state,
            ForwardState::Queued
        );

        q.mark_object_state(&second_digest, ForwardState::Failed)
            .unwrap();
        assert_eq!(
            q.get_object(&first_digest).unwrap().unwrap().state,
            ForwardState::Forwarded
        );
        assert_eq!(
            q.get_object(&second_digest).unwrap().unwrap().state,
            ForwardState::Failed
        );
    }

    #[test]
    fn relay_seen_cache_is_hard_bounded() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        for i in 0..(MAX_RELAY_SEEN_OBJECTS + 32) {
            let digest = sha2::Sha256::digest(i.to_be_bytes());
            let mut d = [0u8; 32];
            d.copy_from_slice(&digest);
            q.mark_object_seen(&d, i as u64 + 1, TransportKind::Lan, "peer")
                .unwrap();
        }
        q.prune_seen_objects((MAX_RELAY_SEEN_OBJECTS + 33) as u64)
            .unwrap();
        let count: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM bridge_seen_objects_v2", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(count as usize <= MAX_RELAY_SEEN_OBJECTS);
    }
}
