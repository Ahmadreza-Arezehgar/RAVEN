//! Persistent opaque forward queue (Bridge V1 store-carry-bridge).
//!
//! Holds packed RavenEnvelopeV1 bytes only — never plaintext / ratchet keys.
//! Survives raven-node restart; expires by envelope TTL / row expires_at_ms.

use rusqlite::{
    params, Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior,
};
use std::net::{IpAddr, SocketAddr};
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
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("bad message_id")]
    BadId,
    #[error("object_digest does not match packed envelope")]
    BadObjectDigest,
    #[error("queue expiry exceeds the signed envelope expiry")]
    ExpiryExceedsEnvelope,
    #[error("queue full (limit {0})")]
    QueueFull(usize),
    #[error("peer queue full (limit {0})")]
    PeerQueueFull(usize),
    #[error("envelope too large ({0} bytes)")]
    TooLarge(usize),
    #[error("relay replay cache full (limit {0})")]
    SeenCacheFull(usize),
    #[error("invalid queue path: {0}")]
    InvalidQueuePath(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeenAdmission {
    Inserted,
    AlreadySeen,
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
/// Terminal rows are useful for diagnostics/dedup for a bounded interval, but
/// must not grow the bridge database forever.
pub const TERMINAL_ROW_RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
pub const MAX_TERMINAL_FORWARD_ROWS: usize = 4_096;
/// Failed/unacknowledged handoffs are retried only after a new explicit pull.
/// Exponential backoff additionally prevents reconnect loops from spraying.
pub const FORWARD_RETRY_BASE_MS: u64 = 5_000;
pub const FORWARD_RETRY_MAX_MS: u64 = 5 * 60 * 1_000;

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
        let mut conn = Connection::open(path)?;
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
               previous_hop TEXT NOT NULL DEFAULT '',
               attempt_count INTEGER NOT NULL DEFAULT 0,
               next_attempt_at_ms INTEGER NOT NULL DEFAULT 0
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
             );
             CREATE TABLE IF NOT EXISTS forward_queue_quarantine (
               quarantine_id INTEGER PRIMARY KEY AUTOINCREMENT,
               message_id BLOB NOT NULL,
               packed BLOB NOT NULL,
               ingress TEXT NOT NULL,
               egress TEXT NOT NULL,
               state INTEGER NOT NULL,
               created_at_ms INTEGER NOT NULL,
               expires_at_ms INTEGER NOT NULL,
               previous_hop TEXT NOT NULL,
               reason TEXT NOT NULL
             );",
        )?;
        ensure_forward_attempt_columns(&mut conn)?;
        migrate_legacy_forward_rows(&mut conn)?;
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

    /// Inspect an existing queue without creating a database, schema, profile
    /// directory, WAL, or migration state. Intended for `raven-node status`.
    pub fn inspect_counts(path: &Path) -> Result<(usize, usize), ForwardQueueError> {
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
            Err(error) => return Err(error.into()),
        };
        if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
            return Err(ForwardQueueError::InvalidQueuePath(
                path.display().to_string(),
            ));
        }
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let pending: i64 = conn.query_row(
            "SELECT COUNT(*) FROM forward_objects_v2 WHERE state IN (0, 1)",
            [],
            |r| r.get(0),
        )?;
        let total: i64 =
            conn.query_row("SELECT COUNT(*) FROM forward_objects_v2", [], |r| r.get(0))?;
        Ok((pending as usize, total as usize))
    }

    pub fn count_pending_for_peer(&self, previous_hop: &str) -> Result<usize, ForwardQueueError> {
        let previous_hop = canonical_peer_key(previous_hop);
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
        let peer = canonical_peer_key(previous_hop);
        if envelope_bytes > i64::MAX as usize {
            return Ok(PeerRateDecision::RateLimited);
        }
        // BEGIN IMMEDIATE serializes the read/check/update across the service's
        // independently opened IPC and bridge SQLite connections.
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        let peer_pending: i64 = tx.query_row(
            "SELECT COUNT(*) FROM forward_objects_v2
             WHERE state IN (0, 1) AND previous_hop = ?1",
            params![&peer],
            |r| r.get(0),
        )?;
        if peer_pending as usize >= self.max_per_peer_pending {
            return Ok(PeerRateDecision::PeerQueueFull);
        }
        let window = self.peer_rate_window_ms.max(1);
        let window_start = (now_ms / window) * window;
        // Drop older windows (keep DB small).
        tx.execute(
            "DELETE FROM bridge_peer_rate WHERE window_start_ms < ?1",
            params![window_start.saturating_sub(window.saturating_mul(2)) as i64],
        )?;
        let row: Option<(i64, i64)> = tx
            .query_row(
                "SELECT enqueue_count, byte_count FROM bridge_peer_rate
                 WHERE peer_key = ?1 AND window_start_ms = ?2",
                params![&peer, window_start as i64],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (count, bytes) = row.unwrap_or((0, 0));
        if count as usize >= self.max_per_peer_enqueues
            || (bytes as u64).saturating_add(envelope_bytes as u64) > self.max_per_peer_bytes
        {
            tx.commit()?;
            return Ok(PeerRateDecision::RateLimited);
        }
        tx.execute(
            "INSERT INTO bridge_peer_rate (peer_key, window_start_ms, enqueue_count, byte_count)
             VALUES (?1, ?2, 1, ?3)
             ON CONFLICT(peer_key, window_start_ms) DO UPDATE SET
               enqueue_count = enqueue_count + 1,
               byte_count = byte_count + excluded.byte_count",
            params![&peer, window_start as i64, envelope_bytes as i64],
        )?;
        tx.commit()?;
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
        let (object_digest, previous_hop) = self.validate_forward_item(item)?;
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        self.enqueue_on(&tx, item, &object_digest, &previous_hop)?;
        tx.commit()?;
        Ok(())
    }

    fn validate_forward_item(
        &self,
        item: &ForwardItem,
    ) -> Result<([u8; 32], String), ForwardQueueError> {
        if item.message_id.len() != 16 {
            return Err(ForwardQueueError::BadId);
        }
        if item.packed_envelope.len() > self.max_bytes {
            return Err(ForwardQueueError::TooLarge(item.packed_envelope.len()));
        }
        let env = Envelope::unpack(&item.packed_envelope).ok_or(ForwardQueueError::BadId)?;
        if env.message_id != item.message_id {
            return Err(ForwardQueueError::BadId);
        }
        let object_digest = authenticated_object_digest(&env);
        if item.object_digest != object_digest {
            return Err(ForwardQueueError::BadObjectDigest);
        }
        // Queue metadata may shorten custody, but it must never extend the
        // lifetime authenticated by the sender inside the envelope.
        if item.expires_at_ms > env.expires_at {
            return Err(ForwardQueueError::ExpiryExceedsEnvelope);
        }
        Ok((object_digest, canonical_peer_key(&item.previous_hop)))
    }

    fn enqueue_on(
        &self,
        tx: &Transaction<'_>,
        item: &ForwardItem,
        object_digest: &[u8; 32],
        previous_hop: &str,
    ) -> Result<bool, ForwardQueueError> {
        // Exact immutable objects are idempotent. Different objects carrying
        // the same public message_id occupy separate bounded rows, preventing
        // a forged first arrival from poisoning a later valid object.
        prune_terminal_rows_on(tx, item.created_at_ms)?;
        let exists: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM forward_objects_v2 WHERE object_digest = ?1",
                params![object_digest.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        if exists.is_none() {
            let pending: i64 = tx.query_row(
                "SELECT COUNT(*) FROM forward_objects_v2 WHERE state IN (0, 1)",
                [],
                |r| r.get(0),
            )?;
            if pending as usize >= self.max_items {
                return Err(ForwardQueueError::QueueFull(self.max_items));
            }
            let peer_pending: i64 = tx.query_row(
                "SELECT COUNT(*) FROM forward_objects_v2
                 WHERE state IN (0, 1) AND previous_hop = ?1",
                params![previous_hop],
                |r| r.get(0),
            )?;
            if peer_pending as usize >= self.max_per_peer_pending {
                return Err(ForwardQueueError::PeerQueueFull(self.max_per_peer_pending));
            }
        }
        // SQLite INTEGER is signed; clamp so u64::MAX does not store as -1.
        let expires_i64 = item.expires_at_ms.min(i64::MAX as u64) as i64;
        let created_i64 = item.created_at_ms.min(i64::MAX as u64) as i64;
        let inserted = tx.execute(
            "INSERT INTO forward_objects_v2
             (object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(object_digest) DO NOTHING",
            params![
                object_digest.as_slice(),
                item.message_id.as_slice(),
                &item.packed_envelope,
                item.ingress.as_str(),
                item.egress.as_str(),
                item.state as u8,
                created_i64,
                expires_i64,
                previous_hop,
            ],
        )?;
        Ok(inserted == 1)
    }

    pub fn mark_object_state(
        &self,
        object_digest: &[u8; 32],
        state: ForwardState,
    ) -> Result<(), ForwardQueueError> {
        self.conn.execute(
            "UPDATE forward_objects_v2
             SET state = ?1,
                 next_attempt_at_ms = CASE WHEN ?1 = 0 THEN 0 ELSE next_attempt_at_ms END
             WHERE object_digest = ?2",
            params![state as u8, object_digest.as_slice()],
        )?;
        Ok(())
    }

    /// Atomically reserve one eligible queued object for a single carrier
    /// handoff. `InFlight` remains retryable after exponential backoff; only a
    /// verifiable higher-layer receipt may transition it to `Forwarded`.
    pub fn claim_object_for_attempt(
        &self,
        object_digest: &[u8; 32],
        now_ms: u64,
    ) -> Result<bool, ForwardQueueError> {
        let row: Option<(u8, u32, u64, u64)> = self
            .conn
            .query_row(
                "SELECT state, attempt_count, next_attempt_at_ms, expires_at_ms
                 FROM forward_objects_v2 WHERE object_digest = ?1",
                params![object_digest.as_slice()],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get::<_, i64>(2)?.max(0) as u64,
                        r.get::<_, i64>(3)?.max(0) as u64,
                    ))
                },
            )
            .optional()?;
        let Some((state, attempts, next_attempt_at, expires_at)) = row else {
            return Ok(false);
        };
        let eligible = state == ForwardState::Queued as u8
            || (state == ForwardState::InFlight as u8 && now_ms >= next_attempt_at);
        if !eligible || now_ms >= expires_at {
            return Ok(false);
        }
        let shift = attempts.min(6);
        let delay = FORWARD_RETRY_BASE_MS
            .saturating_mul(1u64 << shift)
            .min(FORWARD_RETRY_MAX_MS);
        let next = now_ms.saturating_add(delay).min(i64::MAX as u64);
        let changed = self.conn.execute(
            "UPDATE forward_objects_v2
             SET state = ?1, attempt_count = attempt_count + 1, next_attempt_at_ms = ?2
             WHERE object_digest = ?3
               AND (state = 0 OR (state = 1 AND next_attempt_at_ms <= ?4))
               AND expires_at_ms > ?4",
            params![
                ForwardState::InFlight as u8,
                next as i64,
                object_digest.as_slice(),
                now_ms.min(i64::MAX as u64) as i64,
            ],
        )?;
        Ok(changed == 1)
    }

    /// Accept a receipt only for an object currently reserved to a carrier.
    /// The caller is responsible for cryptographically authenticating and
    /// session-binding that receipt before invoking this CAS transition.
    pub fn acknowledge_in_flight(
        &self,
        object_digest: &[u8; 32],
    ) -> Result<bool, ForwardQueueError> {
        let changed = self.conn.execute(
            "UPDATE forward_objects_v2 SET state = ?1
             WHERE object_digest = ?2 AND state = ?3",
            params![
                ForwardState::Forwarded as u8,
                object_digest.as_slice(),
                ForwardState::InFlight as u8,
            ],
        )?;
        Ok(changed == 1)
    }

    /// Pending (Queued/InFlight) that are not expired.
    pub fn pending_ready(&self, now_ms: u64) -> Result<Vec<ForwardItem>, ForwardQueueError> {
        self.expire_stale(now_ms)?;
        let now_i64 = now_ms.min(i64::MAX as u64) as i64;
        let mut stmt = self.conn.prepare(
            "SELECT object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_objects_v2
             WHERE (state = 0 OR (state = 1 AND next_attempt_at_ms <= ?1))
               AND expires_at_ms > ?1
             ORDER BY CASE
                        WHEN state = 0 THEN created_at_ms
                        ELSE next_attempt_at_ms
                      END ASC,
                      created_at_ms ASC,
                      object_digest ASC",
        )?;
        let rows = stmt.query_map(params![now_i64], row_to_v2_item)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn expire_stale(&self, now_ms: u64) -> Result<usize, ForwardQueueError> {
        let now_i64 = now_ms.min(i64::MAX as u64) as i64;
        let n = self.conn.execute(
            "UPDATE forward_objects_v2 SET state = ?1
             WHERE state IN (0, 1) AND expires_at_ms <= ?2",
            params![ForwardState::Expired as u8, now_i64],
        )?;
        Ok(n)
    }

    /// Expire live custody and bound diagnostic terminal history by both age
    /// and a hard row cap.
    pub fn maintain(&self, now_ms: u64) -> Result<(), ForwardQueueError> {
        self.expire_stale(now_ms)?;
        self.prune_terminal_rows(now_ms)?;
        self.prune_seen_objects(now_ms)?;
        Ok(())
    }

    pub fn prune_terminal_rows(&self, now_ms: u64) -> Result<usize, ForwardQueueError> {
        Ok(prune_terminal_rows_on(&self.conn, now_ms)?)
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

    pub fn object_was_seen_at(
        &self,
        object_digest: &[u8; 32],
        now_ms: u64,
    ) -> Result<bool, ForwardQueueError> {
        if now_ms < RELAY_SEEN_TTL_MS {
            return self.object_was_seen(object_digest);
        }
        let cutoff = now_ms
            .saturating_sub(RELAY_SEEN_TTL_MS)
            .min(i64::MAX as u64) as i64;
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM bridge_seen_objects_v2
                 WHERE object_digest = ?1 AND seen_at_ms > ?2",
                params![object_digest.as_slice(), cutoff],
                |row| row.get(0),
            )
            .optional()?;
        Ok(existing.is_some())
    }

    /// Atomically admit durable custody and its replay record. A restart can
    /// therefore never recover a forward row that was committed without the
    /// corresponding active replay guard.
    pub fn enqueue_and_mark_seen(
        &self,
        item: &ForwardItem,
    ) -> Result<SeenAdmission, ForwardQueueError> {
        let (object_digest, previous_hop) = self.validate_forward_item(item)?;
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_expired_seen_objects_on(&tx, item.created_at_ms)?;
        if seen_object_exists_on(&tx, &object_digest)? {
            tx.commit()?;
            return Ok(SeenAdmission::AlreadySeen);
        }
        ensure_seen_capacity_on(&tx)?;
        self.enqueue_on(&tx, item, &object_digest, &previous_hop)?;
        insert_seen_object_on(
            &tx,
            &object_digest,
            item.created_at_ms,
            item.ingress,
            &previous_hop,
        )?;
        tx.commit()?;
        Ok(SeenAdmission::Inserted)
    }

    /// Atomically record a best-effort (store=off) relay object. `Inserted`
    /// is the only outcome that authorizes a handoff; concurrent duplicates
    /// receive `AlreadySeen` and cannot both forward.
    pub fn mark_object_seen(
        &self,
        object_digest: &[u8; 32],
        now_ms: u64,
        ingress: TransportKind,
        previous_hop: &str,
    ) -> Result<SeenAdmission, ForwardQueueError> {
        let previous_hop = canonical_peer_key(previous_hop);
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_expired_seen_objects_on(&tx, now_ms)?;
        if seen_object_exists_on(&tx, object_digest)? {
            tx.commit()?;
            return Ok(SeenAdmission::AlreadySeen);
        }
        ensure_seen_capacity_on(&tx)?;
        insert_seen_object_on(&tx, object_digest, now_ms, ingress, &previous_hop)?;
        tx.commit()?;
        Ok(SeenAdmission::Inserted)
    }

    pub fn prune_seen_objects(&self, now_ms: u64) -> Result<(), ForwardQueueError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_expired_seen_objects_on(&tx, now_ms)?;
        tx.commit()?;
        Ok(())
    }
}

fn prune_terminal_rows_on(conn: &Connection, now_ms: u64) -> Result<usize, rusqlite::Error> {
    let cutoff = now_ms
        .saturating_sub(TERMINAL_ROW_RETENTION_MS)
        .min(i64::MAX as u64) as i64;
    let by_age = conn.execute(
        "DELETE FROM forward_objects_v2
         WHERE state IN (2, 3, 4) AND created_at_ms < ?1",
        params![cutoff],
    )?;
    let by_cap = conn.execute(
        "DELETE FROM forward_objects_v2
         WHERE object_digest IN (
           SELECT object_digest FROM forward_objects_v2
           WHERE state IN (2, 3, 4)
           ORDER BY created_at_ms DESC, object_digest DESC
           LIMIT -1 OFFSET ?1
         )",
        params![MAX_TERMINAL_FORWARD_ROWS as i64],
    )?;
    Ok(by_age + by_cap)
}

fn prune_expired_seen_objects_on(conn: &Connection, now_ms: u64) -> Result<(), rusqlite::Error> {
    if now_ms < RELAY_SEEN_TTL_MS {
        return Ok(());
    }
    let cutoff = now_ms
        .saturating_sub(RELAY_SEEN_TTL_MS)
        .min(i64::MAX as u64) as i64;
    conn.execute(
        "DELETE FROM bridge_seen_objects_v2 WHERE seen_at_ms <= ?1",
        params![cutoff],
    )?;
    Ok(())
}

fn seen_object_exists_on(
    conn: &Connection,
    object_digest: &[u8; 32],
) -> Result<bool, rusqlite::Error> {
    let existing: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM bridge_seen_objects_v2 WHERE object_digest = ?1",
            params![object_digest.as_slice()],
            |row| row.get(0),
        )
        .optional()?;
    Ok(existing.is_some())
}

fn ensure_seen_capacity_on(conn: &Connection) -> Result<(), ForwardQueueError> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM bridge_seen_objects_v2", [], |row| {
        row.get(0)
    })?;
    if count as usize >= MAX_RELAY_SEEN_OBJECTS {
        return Err(ForwardQueueError::SeenCacheFull(MAX_RELAY_SEEN_OBJECTS));
    }
    Ok(())
}

fn insert_seen_object_on(
    conn: &Connection,
    object_digest: &[u8; 32],
    now_ms: u64,
    ingress: TransportKind,
    previous_hop: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO bridge_seen_objects_v2
         (object_digest, seen_at_ms, ingress, previous_hop)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            object_digest.as_slice(),
            now_ms.min(i64::MAX as u64) as i64,
            ingress.as_str(),
            previous_hop
        ],
    )?;
    Ok(())
}

/// TCP source ports are ephemeral and must never create a fresh abuse bucket.
/// Preserve non-IP peer identifiers used by authenticated/non-TCP adapters.
fn canonical_peer_key(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Ok(addr) = trimmed.parse::<SocketAddr>() {
        return addr.ip().to_string();
    }
    if let Ok(ip) = trimmed.parse::<IpAddr>() {
        return ip.to_string();
    }
    trimmed.to_string()
}

fn ensure_forward_attempt_columns(conn: &mut Connection) -> Result<(), ForwardQueueError> {
    // Serialize the read-then-ALTER upgrade. Without an IMMEDIATE transaction,
    // two first openers of a pre-attempt schema can both observe a missing
    // column and one then fails with a duplicate-column race.
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let columns = {
        let mut stmt = tx.prepare("PRAGMA table_info(forward_objects_v2)")?;
        let columns = stmt
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        columns
    };
    if !columns.iter().any(|name| name == "attempt_count") {
        tx.execute(
            "ALTER TABLE forward_objects_v2
             ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !columns.iter().any(|name| name == "next_attempt_at_ms") {
        tx.execute(
            "ALTER TABLE forward_objects_v2
             ADD COLUMN next_attempt_at_ms INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// Idempotently drain the original message-id-keyed queue into V2.
///
/// This deliberately runs on every open instead of relying on a permanent
/// marker: an older binary may be used after an upgrade and write fresh legacy
/// custody. `IMMEDIATE` serializes concurrent openers before either one reads
/// the source table, so a valid row is inserted at most once and deleted only
/// in the same transaction. Malformed live custody is moved byte-for-byte to a
/// durable quarantine instead of being silently discarded.
fn migrate_legacy_forward_rows(conn: &mut Connection) -> Result<(), ForwardQueueError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let legacy = {
        let mut stmt = tx.prepare(
            "SELECT message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop
             FROM forward_queue WHERE state IN (0, 1)",
        )?;
        let rows = stmt.query_map([], row_to_legacy_item_raw)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        out
    };

    for row in legacy {
        let mut message_id = [0u8; 16];
        if row.message_id.len() != message_id.len() {
            quarantine_legacy_row(&tx, &row, "message_id is not 16 bytes")?;
            continue;
        }
        message_id.copy_from_slice(&row.message_id);
        let Some(env) = Envelope::unpack(&row.packed_envelope) else {
            quarantine_legacy_row(&tx, &row, "packed envelope is malformed")?;
            continue;
        };
        if env.message_id != message_id {
            quarantine_legacy_row(
                &tx,
                &row,
                "legacy key does not match signed envelope message_id",
            )?;
            continue;
        }
        let Some(ingress) = parse_transport_strict(&row.ingress) else {
            quarantine_legacy_row(&tx, &row, "legacy ingress transport is unknown")?;
            continue;
        };
        let Some(egress) = parse_transport_strict(&row.egress) else {
            quarantine_legacy_row(&tx, &row, "legacy egress transport is unknown")?;
            continue;
        };
        let digest = authenticated_object_digest(&env);
        // Never preserve a legacy queue lifetime beyond the expiry signed into
        // the immutable envelope.
        let expires_at_ms = (row.expires_at_ms.max(0) as u64).min(env.expires_at);
        tx.execute(
            "INSERT OR IGNORE INTO forward_objects_v2
             (object_digest, message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                digest.as_slice(),
                message_id.as_slice(),
                &row.packed_envelope,
                ingress.as_str(),
                egress.as_str(),
                row.state as u8,
                row.created_at_ms.max(0),
                expires_at_ms.min(i64::MAX as u64) as i64,
                &row.previous_hop,
            ],
        )?;
        delete_legacy_row(&tx, &row.message_id)?;
    }

    // Terminal legacy rows carry no live custody and must not reappear after
    // V2 diagnostic-retention pruning.
    tx.execute("DELETE FROM forward_queue WHERE state NOT IN (0, 1)", [])?;
    tx.commit()?;
    Ok(())
}

#[derive(Debug)]
struct LegacyForwardRow {
    message_id: Vec<u8>,
    packed_envelope: Vec<u8>,
    ingress: String,
    egress: String,
    state: i64,
    created_at_ms: i64,
    expires_at_ms: i64,
    previous_hop: String,
}

fn row_to_legacy_item_raw(r: &rusqlite::Row<'_>) -> rusqlite::Result<LegacyForwardRow> {
    Ok(LegacyForwardRow {
        message_id: r.get(0)?,
        packed_envelope: r.get(1)?,
        ingress: r.get(2)?,
        egress: r.get(3)?,
        state: r.get(4)?,
        created_at_ms: r.get(5)?,
        expires_at_ms: r.get(6)?,
        previous_hop: r.get(7)?,
    })
}

fn delete_legacy_row(
    tx: &rusqlite::Transaction<'_>,
    message_id: &[u8],
) -> Result<(), ForwardQueueError> {
    tx.execute(
        "DELETE FROM forward_queue WHERE message_id = ?1",
        params![message_id],
    )?;
    Ok(())
}

fn quarantine_legacy_row(
    tx: &rusqlite::Transaction<'_>,
    row: &LegacyForwardRow,
    reason: &str,
) -> Result<(), ForwardQueueError> {
    tx.execute(
        "INSERT INTO forward_queue_quarantine
         (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop, reason)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            &row.message_id,
            &row.packed_envelope,
            &row.ingress,
            &row.egress,
            row.state,
            row.created_at_ms,
            row.expires_at_ms,
            &row.previous_hop,
            reason,
        ],
    )?;
    delete_legacy_row(tx, &row.message_id)
}

fn parse_transport_strict(s: &str) -> Option<TransportKind> {
    match s {
        "ble" => Some(TransportKind::Ble),
        "lan" => Some(TransportKind::Lan),
        "internet" => Some(TransportKind::Internet),
        "mock_ble" => Some(TransportKind::MockBle),
        _ => None,
    }
}

fn parse_transport(s: &str) -> TransportKind {
    parse_transport_strict(s).unwrap_or(TransportKind::MockBle)
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
    use std::sync::{Arc, Barrier};
    use tempfile::tempdir;

    fn packed_with_body_and_expiry(mid: [u8; 16], body: &[u8], expires_at: u64) -> Vec<u8> {
        let identity = Identity::from_seed(&[mid[0].wrapping_add(1); 32]);
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: mid,
            routing_tag: [1u8; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at,
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

    fn packed_with_body(mid: [u8; 16], body: &[u8]) -> Vec<u8> {
        packed_with_body_and_expiry(mid, body, 10_000)
    }

    fn packed_with_expiry(mid: [u8; 16], expires_at: u64) -> Vec<u8> {
        packed_with_body_and_expiry(mid, &[mid[0], 3, 4], expires_at)
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
            let packed_envelope = packed_with_expiry(mid, now + 60_000);
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
        let packed_envelope = packed_with_expiry(mid, now + 60_000);
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
    fn concurrent_global_capacity_admission_is_atomic() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("global-cap.sqlite");
        let q1 = ForwardQueue::open_with_limits(&path, 1, MAX_ENVELOPE_BYTES).unwrap();
        let q2 = ForwardQueue::open_with_limits(&path, 1, MAX_ENVELOPE_BYTES).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q1.enqueue(&item([0x41; 16], packed([0x41; 16])))
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.enqueue(&item([0x42; 16], packed([0x42; 16])))
        });
        let results = [h1.join().unwrap(), h2.join().unwrap()];
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(ForwardQueueError::QueueFull(1))))
                .count(),
            1
        );
        assert_eq!(
            ForwardQueue::open(&path).unwrap().count_pending().unwrap(),
            1
        );
    }

    #[test]
    fn concurrent_per_peer_capacity_admission_is_atomic() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("peer-cap.sqlite");
        let open = || {
            ForwardQueue::open_with_peer_limits(
                &path,
                10,
                MAX_ENVELOPE_BYTES,
                1,
                100,
                1_000_000,
                60_000,
            )
            .unwrap()
        };
        let q1 = open();
        let q2 = open();
        let mut first = item([0x51; 16], packed([0x51; 16]));
        first.previous_hop = "same-peer".into();
        let mut second = item([0x52; 16], packed([0x52; 16]));
        second.previous_hop = "same-peer".into();
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q1.enqueue(&first)
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.enqueue(&second)
        });
        let results = [h1.join().unwrap(), h2.join().unwrap()];
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(ForwardQueueError::PeerQueueFull(1))))
                .count(),
            1
        );
        assert_eq!(open().count_pending_for_peer("same-peer").unwrap(), 1);
    }

    #[test]
    fn concurrent_peer_rate_admission_is_atomic() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("peer-rate.sqlite");
        let open = || {
            ForwardQueue::open_with_peer_limits(
                &path,
                10,
                MAX_ENVELOPE_BYTES,
                10,
                1,
                1_000_000,
                60_000,
            )
            .unwrap()
        };
        let q1 = open();
        let q2 = open();
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q1.check_peer_rate("same-peer", 1_700_000_000_000, 10)
                .unwrap()
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.check_peer_rate("same-peer", 1_700_000_000_001, 10)
                .unwrap()
        });
        let results = [h1.join().unwrap(), h2.join().unwrap()];
        assert_eq!(
            results
                .iter()
                .filter(|decision| **decision == PeerRateDecision::Allow)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|decision| **decision == PeerRateDecision::RateLimited)
                .count(),
            1
        );
    }

    #[test]
    fn tcp_source_ports_share_one_rate_bucket() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open_with_peer_limits(
            &dir.path().join("fwd.sqlite"),
            512,
            MAX_ENVELOPE_BYTES,
            64,
            1,
            1_000_000,
            60_000,
        )
        .unwrap();
        let now = 1_700_000_000_000u64;
        assert_eq!(
            q.check_peer_rate("192.0.2.10:41000", now, 10).unwrap(),
            PeerRateDecision::Allow
        );
        assert_eq!(
            q.check_peer_rate("192.0.2.10:52000", now + 1, 10).unwrap(),
            PeerRateDecision::RateLimited
        );
        assert_eq!(canonical_peer_key("[2001:db8::1]:1234"), "2001:db8::1");
    }

    #[test]
    fn in_flight_retry_requires_backoff_and_new_claim() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let now = 1_700_000_000_000u64;
        let mid = [0x31; 16];
        let mut row = item(mid, packed_with_expiry(mid, now + 60_000));
        row.created_at_ms = now;
        row.expires_at_ms = now + 60_000;
        let digest = row.object_digest;
        q.enqueue(&row).unwrap();

        assert!(q.claim_object_for_attempt(&digest, now).unwrap());
        assert_eq!(
            q.get_object(&digest).unwrap().unwrap().state,
            ForwardState::InFlight
        );
        assert!(!q.claim_object_for_attempt(&digest, now + 1).unwrap());
        assert!(q.pending_ready(now + 1).unwrap().is_empty());
        assert!(q
            .claim_object_for_attempt(&digest, now + FORWARD_RETRY_BASE_MS)
            .unwrap());
        assert!(q.acknowledge_in_flight(&digest).unwrap());
        assert!(!q.acknowledge_in_flight(&digest).unwrap());
        assert_eq!(
            q.get_object(&digest).unwrap().unwrap().state,
            ForwardState::Forwarded
        );
    }

    #[test]
    fn oldest_ready_retry_is_not_starved_by_new_queued_rows() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();

        let retry_mid = [0x39; 16];
        let mut retry = item(retry_mid, packed_with_expiry(retry_mid, 20_000));
        retry.created_at_ms = 100;
        retry.expires_at_ms = 20_000;
        let retry_digest = retry.object_digest;
        q.enqueue(&retry).unwrap();
        assert!(q.claim_object_for_attempt(&retry_digest, 100).unwrap());

        // This object is freshly queued after the older retry became eligible.
        // A state-first ORDER BY would select it first forever under sustained
        // ingress, starving receipt-bound retries.
        let queued_mid = [0x3A; 16];
        let mut queued = item(queued_mid, packed_with_expiry(queued_mid, 20_000));
        queued.created_at_ms = 6_000;
        queued.expires_at_ms = 20_000;
        let queued_digest = queued.object_digest;
        q.enqueue(&queued).unwrap();

        let ready = q.pending_ready(7_000).unwrap();
        assert_eq!(ready.len(), 2);
        assert_eq!(ready[0].object_digest, retry_digest);
        assert_eq!(ready[0].state, ForwardState::InFlight);
        assert_eq!(ready[1].object_digest, queued_digest);
        assert_eq!(ready[1].state, ForwardState::Queued);
    }

    #[test]
    fn duplicate_enqueue_preserves_in_flight_backoff_and_terminal_state() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let now = 1_000u64;
        let mid = [0x33; 16];
        let mut row = item(mid, packed(mid));
        row.created_at_ms = now;
        row.expires_at_ms = 9_000;
        let digest = row.object_digest;
        q.enqueue(&row).unwrap();
        assert!(q.claim_object_for_attempt(&digest, now).unwrap());

        let before: (u8, u32, i64, i64, String) = q
            .conn
            .query_row(
                "SELECT state, attempt_count, next_attempt_at_ms, expires_at_ms, previous_hop
                 FROM forward_objects_v2 WHERE object_digest = ?1",
                params![digest.as_slice()],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(before.0, ForwardState::InFlight as u8);
        assert_eq!(before.1, 1);
        assert_eq!(before.2, (now + FORWARD_RETRY_BASE_MS) as i64);

        // A caller retry may propose fresh queue metadata, but the durable
        // object identity already owns this row and its custody CAS state.
        let mut duplicate = row.clone();
        duplicate.state = ForwardState::Queued;
        duplicate.created_at_ms = now + 100;
        duplicate.expires_at_ms = 9_500;
        duplicate.previous_hop = "different-hop".into();
        q.enqueue(&duplicate).unwrap();
        let after: (u8, u32, i64, i64, String) = q
            .conn
            .query_row(
                "SELECT state, attempt_count, next_attempt_at_ms, expires_at_ms, previous_hop
                 FROM forward_objects_v2 WHERE object_digest = ?1",
                params![digest.as_slice()],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(after, before);

        assert!(q.acknowledge_in_flight(&digest).unwrap());
        q.enqueue(&duplicate).unwrap();
        assert_eq!(
            q.get_object(&digest).unwrap().unwrap().state,
            ForwardState::Forwarded
        );

        let failed_mid = [0x34; 16];
        let failed = item(failed_mid, packed(failed_mid));
        let failed_digest = failed.object_digest;
        q.enqueue(&failed).unwrap();
        q.mark_object_state(&failed_digest, ForwardState::Failed)
            .unwrap();
        q.enqueue(&failed).unwrap();
        assert_eq!(
            q.get_object(&failed_digest).unwrap().unwrap().state,
            ForwardState::Failed
        );
    }

    #[test]
    fn signed_expiry_is_an_upper_bound_and_exact_boundary_is_expired() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let mid = [0x35; 16];
        let mut row = item(mid, packed(mid));
        row.expires_at_ms = 100;
        let digest = row.object_digest;
        q.enqueue(&row).unwrap();
        assert_eq!(q.pending_ready(99).unwrap().len(), 1);
        assert!(q.pending_ready(100).unwrap().is_empty());
        assert!(!q.claim_object_for_attempt(&digest, 100).unwrap());
        assert_eq!(
            q.get_object(&digest).unwrap().unwrap().state,
            ForwardState::Expired
        );

        let other_mid = [0x36; 16];
        let mut extended = item(other_mid, packed(other_mid));
        extended.expires_at_ms = 10_001;
        assert!(matches!(
            q.enqueue(&extended),
            Err(ForwardQueueError::ExpiryExceedsEnvelope)
        ));
    }

    #[test]
    fn terminal_rows_are_pruned_by_retention() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("fwd.sqlite")).unwrap();
        let mid = [0x32; 16];
        let row = item(mid, packed(mid));
        let digest = row.object_digest;
        q.enqueue(&row).unwrap();
        q.mark_object_state(&digest, ForwardState::Failed).unwrap();
        q.prune_terminal_rows(TERMINAL_ROW_RETENTION_MS + 2)
            .unwrap();
        assert!(q.get_object(&digest).unwrap().is_none());
    }

    #[test]
    fn legacy_migration_never_revives_terminal_rows() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        let live_mid = [0x37; 16];
        let terminal_mid = [0x38; 16];
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE forward_queue (
                   message_id BLOB PRIMARY KEY NOT NULL,
                   packed BLOB NOT NULL,
                   ingress TEXT NOT NULL,
                   egress TEXT NOT NULL,
                   state INTEGER NOT NULL,
                   created_at_ms INTEGER NOT NULL,
                   expires_at_ms INTEGER NOT NULL,
                   previous_hop TEXT NOT NULL DEFAULT ''
                 );",
            )
            .unwrap();
            for (mid, state) in [
                (live_mid, ForwardState::Queued),
                (terminal_mid, ForwardState::Forwarded),
            ] {
                conn.execute(
                    "INSERT INTO forward_queue
                     (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
                     VALUES (?1, ?2, 'lan', 'ble', ?3, 1, 10000, 'legacy-peer')",
                    params![mid.as_slice(), packed(mid), state as u8],
                )
                .unwrap();
            }
        }

        let live_digest = item(live_mid, packed(live_mid)).object_digest;
        {
            let q = ForwardQueue::open(&path).unwrap();
            assert!(q.get(&live_mid).unwrap().is_some());
            assert!(q.get(&terminal_mid).unwrap().is_none());
            let legacy_count: i64 = q
                .conn
                .query_row("SELECT COUNT(*) FROM forward_queue", [], |r| r.get(0))
                .unwrap();
            assert_eq!(legacy_count, 0);
            q.mark_object_state(&live_digest, ForwardState::Failed)
                .unwrap();
            q.prune_terminal_rows(TERMINAL_ROW_RETENTION_MS + 2)
                .unwrap();
            assert!(q.get_object(&live_digest).unwrap().is_none());
        }

        // Reopening after retention pruning must not import the old source row.
        let q = ForwardQueue::open(&path).unwrap();
        assert!(q.get_object(&live_digest).unwrap().is_none());
        assert_eq!(q.count_all().unwrap(), 0);
    }

    #[test]
    fn legacy_row_written_after_old_marker_is_migrated_once() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        drop(ForwardQueue::open(&path).unwrap());

        let mid = [0x3B; 16];
        let packed = packed(mid);
        {
            let conn = Connection::open(&path).unwrap();
            // Simulate the permanent marker written by the prior upgrader,
            // followed by a downgrade that writes fresh legacy custody.
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS bridge_schema_migrations (
                   name TEXT PRIMARY KEY NOT NULL
                 );
                 INSERT OR IGNORE INTO bridge_schema_migrations (name)
                 VALUES ('legacy_forward_queue_to_objects_v2_v1');",
            )
            .unwrap();
            conn.execute(
                "INSERT INTO forward_queue
                 (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
                 VALUES (?1, ?2, 'lan', 'ble', 0, 1, 10000, 'downgraded-peer')",
                params![mid.as_slice(), &packed],
            )
            .unwrap();
        }

        let q = ForwardQueue::open(&path).unwrap();
        assert!(q.get(&mid).unwrap().is_some());
        assert_eq!(q.count_all().unwrap(), 1);
        drop(q);
        let reopened = ForwardQueue::open(&path).unwrap();
        assert_eq!(reopened.count_all().unwrap(), 1);
        let legacy_count: i64 = reopened
            .conn
            .query_row("SELECT COUNT(*) FROM forward_queue", [], |r| r.get(0))
            .unwrap();
        assert_eq!(legacy_count, 0);
    }

    #[test]
    fn concurrent_openers_migrate_one_valid_legacy_object_once() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        drop(ForwardQueue::open(&path).unwrap());
        let mid = [0x3C; 16];
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute(
                "INSERT INTO forward_queue
                 (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
                 VALUES (?1, ?2, 'lan', 'ble', 0, 1, 10000, 'legacy-peer')",
                params![mid.as_slice(), packed(mid)],
            )
            .unwrap();
        }

        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let path = path.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                ForwardQueue::open(&path).map(|queue| queue.count_all().unwrap())
            }));
        }
        for thread in threads {
            assert_eq!(thread.join().unwrap().unwrap(), 1);
        }

        let q = ForwardQueue::open(&path).unwrap();
        assert_eq!(q.count_all().unwrap(), 1);
        assert!(q.get(&mid).unwrap().is_some());
        let legacy_count: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM forward_queue", [], |r| r.get(0))
            .unwrap();
        assert_eq!(legacy_count, 0);
    }

    #[test]
    fn concurrent_openers_upgrade_pre_attempt_schema_once() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE forward_objects_v2 (
                   object_digest BLOB PRIMARY KEY NOT NULL,
                   message_id BLOB NOT NULL,
                   packed BLOB NOT NULL,
                   ingress TEXT NOT NULL,
                   egress TEXT NOT NULL,
                   state INTEGER NOT NULL,
                   created_at_ms INTEGER NOT NULL,
                   expires_at_ms INTEGER NOT NULL,
                   previous_hop TEXT NOT NULL DEFAULT ''
                 );",
            )
            .unwrap();
        }

        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let path = path.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                ForwardQueue::open(&path).map(drop)
            }));
        }
        for thread in threads {
            thread.join().unwrap().unwrap();
        }

        let conn = Connection::open(&path).unwrap();
        let columns = {
            let mut stmt = conn
                .prepare("PRAGMA table_info(forward_objects_v2)")
                .unwrap();
            stmt.query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        assert_eq!(
            columns
                .iter()
                .filter(|column| column.as_str() == "attempt_count")
                .count(),
            1
        );
        assert_eq!(
            columns
                .iter()
                .filter(|column| column.as_str() == "next_attempt_at_ms")
                .count(),
            1
        );
    }

    #[test]
    fn malformed_and_mismatched_live_legacy_custody_is_quarantined_exactly() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        drop(ForwardQueue::open(&path).unwrap());

        let malformed_mid = [0x3D; 16];
        let malformed = b"not-a-raven-envelope".to_vec();
        let mismatched_mid = [0x3E; 16];
        let packed_other = packed([0x3F; 16]);
        let unknown_transport_mid = [0x40; 16];
        let unknown_transport_packed = packed(unknown_transport_mid);
        {
            let conn = Connection::open(&path).unwrap();
            for (mid, bytes) in [
                (malformed_mid, malformed.clone()),
                (mismatched_mid, packed_other.clone()),
            ] {
                conn.execute(
                    "INSERT INTO forward_queue
                     (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
                     VALUES (?1, ?2, 'lan', 'ble', 0, 1, 10000, 'legacy-peer')",
                    params![mid.as_slice(), bytes],
                )
                .unwrap();
            }
            conn.execute(
                "INSERT INTO forward_queue
                 (message_id, packed, ingress, egress, state, created_at_ms, expires_at_ms, previous_hop)
                 VALUES (?1, ?2, 'carrier-from-future', 'ble', 0, 1, 10000, 'legacy-peer')",
                params![unknown_transport_mid.as_slice(), &unknown_transport_packed],
            )
            .unwrap();
        }

        let q = ForwardQueue::open(&path).unwrap();
        assert_eq!(q.count_all().unwrap(), 0);
        let source_count: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM forward_queue", [], |r| r.get(0))
            .unwrap();
        assert_eq!(source_count, 0);
        let quarantined: Vec<(Vec<u8>, Vec<u8>, String)> = {
            let mut stmt = q
                .conn
                .prepare(
                    "SELECT message_id, packed, reason FROM forward_queue_quarantine
                     ORDER BY quarantine_id ASC",
                )
                .unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        assert_eq!(quarantined.len(), 3);
        assert_eq!(quarantined[0].0, malformed_mid);
        assert_eq!(quarantined[0].1, malformed);
        assert!(quarantined[0].2.contains("malformed"));
        assert_eq!(quarantined[1].0, mismatched_mid);
        assert_eq!(quarantined[1].1, packed_other);
        assert!(quarantined[1].2.contains("does not match"));
        assert_eq!(quarantined[2].0, unknown_transport_mid);
        assert_eq!(quarantined[2].1, unknown_transport_packed);
        assert!(quarantined[2].2.contains("transport is unknown"));
    }

    #[test]
    fn read_only_counts_do_not_create_missing_queue_or_parent() {
        let dir = tempdir().unwrap();
        let parent = dir.path().join("fresh-profile");
        let db = parent.join("forward_queue.sqlite");
        assert_eq!(ForwardQueue::inspect_counts(&db).unwrap(), (0, 0));
        assert!(!parent.exists());
        assert!(!db.exists());
    }

    #[test]
    fn read_only_counts_reject_existing_non_regular_path() {
        let dir = tempdir().unwrap();
        let database = dir.path().join("forward_queue.sqlite");
        std::fs::create_dir(&database).unwrap();
        assert!(matches!(
            ForwardQueue::inspect_counts(&database),
            Err(ForwardQueueError::InvalidQueuePath(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn read_only_counts_reject_file_and_dangling_symlinks() {
        use std::os::unix::fs::symlink;

        let dir = tempdir().unwrap();
        let target = dir.path().join("real.sqlite");
        ForwardQueue::open(&target).unwrap();
        let linked = dir.path().join("linked.sqlite");
        symlink(&target, &linked).unwrap();
        assert!(matches!(
            ForwardQueue::inspect_counts(&linked),
            Err(ForwardQueueError::InvalidQueuePath(_))
        ));

        let dangling = dir.path().join("dangling.sqlite");
        symlink(dir.path().join("missing.sqlite"), &dangling).unwrap();
        assert!(matches!(
            ForwardQueue::inspect_counts(&dangling),
            Err(ForwardQueueError::InvalidQueuePath(_))
        ));
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
        let path = dir.path().join("fwd.sqlite");
        let q = ForwardQueue::open(&path).unwrap();
        let mut oldest = [0u8; 32];
        for i in 0..(MAX_RELAY_SEEN_OBJECTS - 1) {
            let digest = sha2::Sha256::digest(i.to_be_bytes());
            let mut d = [0u8; 32];
            d.copy_from_slice(&digest);
            if i == 0 {
                oldest = d;
            }
            assert_eq!(
                q.mark_object_seen(&d, i as u64 + 1, TransportKind::Lan, "peer")
                    .unwrap(),
                SeenAdmission::Inserted
            );
        }
        let q2 = ForwardQueue::open(&path).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let first = [0xA1; 32];
        let second = [0xA2; 32];
        let concurrent_now = (MAX_RELAY_SEEN_OBJECTS + 100) as u64;
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q.mark_object_seen(&first, concurrent_now, TransportKind::Lan, "peer-a")
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.mark_object_seen(&second, concurrent_now, TransportKind::Lan, "peer-b")
        });
        let results = [h1.join().unwrap(), h2.join().unwrap()];
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Ok(SeenAdmission::Inserted)))
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(ForwardQueueError::SeenCacheFull(_))))
                .count(),
            1
        );
        let q = ForwardQueue::open(&path).unwrap();
        let count: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM bridge_seen_objects_v2", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count as usize, MAX_RELAY_SEEN_OBJECTS);

        // A full active cache never evicts an older replay guard. Re-marking
        // an active digest remains idempotent, while a fresh digest fails.
        assert!(q.object_was_seen(&oldest).unwrap());
        assert_eq!(
            q.mark_object_seen(
                &oldest,
                concurrent_now + 1,
                TransportKind::Lan,
                "peer-oldest"
            )
            .unwrap(),
            SeenAdmission::AlreadySeen
        );
        let fresh = [0xA3; 32];
        assert!(matches!(
            q.mark_object_seen(&fresh, concurrent_now + 1, TransportKind::Lan, "peer-fresh"),
            Err(ForwardQueueError::SeenCacheFull(MAX_RELAY_SEEN_OBJECTS))
        ));
        assert!(!q.object_was_seen(&fresh).unwrap());
        let count_after_duplicate: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM bridge_seen_objects_v2", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count_after_duplicate, count);
    }

    #[test]
    fn concurrent_identical_seen_admission_has_one_winner() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("fwd.sqlite");
        let first_queue = ForwardQueue::open(&path).unwrap();
        let second_queue = ForwardQueue::open(&path).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let first_barrier = Arc::clone(&barrier);
        let second_barrier = Arc::clone(&barrier);
        let digest = [0xD5; 32];
        let first = std::thread::spawn(move || {
            first_barrier.wait();
            first_queue.mark_object_seen(&digest, 1, TransportKind::Lan, "peer-a")
        });
        let second = std::thread::spawn(move || {
            second_barrier.wait();
            second_queue.mark_object_seen(&digest, 1, TransportKind::Lan, "peer-b")
        });
        let results = [
            first.join().unwrap().unwrap(),
            second.join().unwrap().unwrap(),
        ];
        assert_eq!(
            results
                .iter()
                .filter(|result| **result == SeenAdmission::Inserted)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| **result == SeenAdmission::AlreadySeen)
                .count(),
            1
        );

        let queue = ForwardQueue::open(&path).unwrap();
        let count: i64 = queue
            .conn
            .query_row("SELECT COUNT(*) FROM bridge_seen_objects_v2", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
    }
}
