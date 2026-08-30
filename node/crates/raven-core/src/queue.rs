//! Persistent outgoing queue (SQLite). Delivery advances only on signed ACK.

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

use crate::envelope::Envelope;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum DeliveryState {
    Queued = 0,
    Sent = 1,
    Delivered = 2,
    Failed = 3,
}

impl DeliveryState {
    fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Sent,
            2 => Self::Delivered,
            3 => Self::Failed,
            _ => Self::Queued,
        }
    }
}

#[derive(Debug, Clone)]
pub struct QueueItem {
    pub message_id: [u8; 16],
    pub packed_envelope: Vec<u8>,
    pub peer_addr: String,
    pub state: DeliveryState,
    pub created_at_ms: u64,
}

#[derive(Error, Debug)]
pub enum QueueError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("bad message_id length")]
    BadId,
    #[error("message_id collision with a different immutable outbound object")]
    MessageIdCollision,
    #[error("outgoing queue full (limit {0})")]
    QueueFull(usize),
    #[error("outgoing live-byte budget exhausted (limit {0})")]
    QueueByteBudget(u64),
    #[error("outgoing envelope too large ({0} bytes)")]
    TooLarge(usize),
    #[error("inbound replay cache full (limit {0})")]
    SeenCacheFull(usize),
}

/// The 10k reliability gate deliberately exercises 10,000 simultaneous live
/// rows, so the production hard ceiling leaves headroom above that contract.
pub const MAX_LIVE_OUTGOING_ROWS: usize = 16_384;
pub const MAX_LIVE_OUTGOING_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_OUTGOING_ENVELOPE_BYTES: usize = crate::forward_queue::MAX_ENVELOPE_BYTES;
pub const MAX_TERMINAL_OUTGOING_ROWS: usize = 4_096;
pub const MAX_SEEN_INBOUND_ROWS: usize = 16_384;
pub const SEEN_INBOUND_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

pub struct OutgoingQueue {
    conn: Connection,
    max_live_rows: usize,
    max_live_bytes: u64,
    max_terminal_rows: usize,
    max_seen_rows: usize,
}

impl OutgoingQueue {
    pub fn open(path: &Path) -> Result<Self, QueueError> {
        Self::open_with_limits(
            path,
            MAX_LIVE_OUTGOING_ROWS,
            MAX_LIVE_OUTGOING_BYTES,
            MAX_TERMINAL_OUTGOING_ROWS,
            MAX_SEEN_INBOUND_ROWS,
        )
    }

    fn open_with_limits(
        path: &Path,
        max_live_rows: usize,
        max_live_bytes: u64,
        max_terminal_rows: usize,
        max_seen_rows: usize,
    ) -> Result<Self, QueueError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA busy_timeout=10000;
             CREATE TABLE IF NOT EXISTS outgoing (
               message_id BLOB PRIMARY KEY NOT NULL,
               packed BLOB NOT NULL,
               peer_addr TEXT NOT NULL,
               state INTEGER NOT NULL,
               created_at_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_outgoing_terminal_order
               ON outgoing(created_at_ms, message_id) WHERE state IN (2, 3);
             CREATE TABLE IF NOT EXISTS seen_inbound (
               message_id BLOB PRIMARY KEY NOT NULL,
               seen_at_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_seen_inbound_time
               ON seen_inbound(seen_at_ms, message_id);",
        )?;
        let queue = Self {
            conn,
            max_live_rows,
            max_live_bytes,
            max_terminal_rows,
            max_seen_rows,
        };
        queue.maintain_bounds(system_now_ms())?;
        queue.validate_live_bounds()?;
        Ok(queue)
    }

    pub fn enqueue(&self, item: &QueueItem) -> Result<(), QueueError> {
        if item.message_id.len() != 16 {
            return Err(QueueError::BadId);
        }
        // BEGIN IMMEDIATE makes the existence check, capacity admission and
        // insert one cross-connection operation. Exact retries stay idempotent
        // without surfacing a transient UNIQUE error, while a conflicting
        // immutable object reliably reports MessageIdCollision.
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
        let existing: Option<(Vec<u8>, String)> = tx
            .query_row(
                "SELECT packed, peer_addr FROM outgoing WHERE message_id = ?1",
                params![item.message_id.as_slice()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((packed, peer_addr)) = existing {
            tx.commit()?;
            if packed == item.packed_envelope && peer_addr == item.peer_addr {
                return Ok(());
            }
            return Err(QueueError::MessageIdCollision);
        }
        if item.packed_envelope.len() > MAX_OUTGOING_ENVELOPE_BYTES {
            tx.commit()?;
            return Err(QueueError::TooLarge(item.packed_envelope.len()));
        }
        if matches!(item.state, DeliveryState::Queued | DeliveryState::Sent) {
            let (live, live_bytes): (i64, i64) = tx.query_row(
                "SELECT COUNT(*), COALESCE(SUM(length(packed)), 0)
                 FROM outgoing WHERE state IN (0, 1)",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            if live as usize >= self.max_live_rows {
                tx.commit()?;
                return Err(QueueError::QueueFull(self.max_live_rows));
            }
            if (live_bytes.max(0) as u64).saturating_add(item.packed_envelope.len() as u64)
                > self.max_live_bytes
            {
                tx.commit()?;
                return Err(QueueError::QueueByteBudget(self.max_live_bytes));
            }
        }
        tx.execute(
            "INSERT INTO outgoing (message_id, packed, peer_addr, state, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                item.message_id.as_slice(),
                item.packed_envelope,
                item.peer_addr,
                item.state as u8,
                item.created_at_ms.min(i64::MAX as u64) as i64
            ],
        )?;
        if matches!(item.state, DeliveryState::Delivered | DeliveryState::Failed) {
            prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn mark_state(
        &self,
        message_id: &[u8; 16],
        state: DeliveryState,
    ) -> Result<(), QueueError> {
        // Delivery is monotonic. In particular, a concurrent transport-write
        // completion must never regress Delivered back to Sent.
        let predicate = match state {
            DeliveryState::Queued => "state = 0",
            DeliveryState::Sent => "state = 0",
            DeliveryState::Delivered | DeliveryState::Failed => "state IN (0, 1)",
        };
        let sql = format!("UPDATE outgoing SET state = ?1 WHERE message_id = ?2 AND ({predicate})");
        if matches!(state, DeliveryState::Delivered | DeliveryState::Failed) {
            let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
            tx.execute(&sql, params![state as u8, message_id.as_slice()])?;
            prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
            tx.commit()?;
        } else {
            self.conn
                .execute(&sql, params![state as u8, message_id.as_slice()])?;
        }
        Ok(())
    }

    /// Compare-and-set used by authenticated receipt handling. Returns true
    /// exactly once for a live Queued/Sent row; duplicates and terminal rows
    /// are no-ops, which prevents duplicate UI delivery events.
    pub fn mark_delivered_once(&self, message_id: &[u8; 16]) -> Result<bool, QueueError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE outgoing SET state = ?1
             WHERE message_id = ?2 AND state IN (0, 1)",
            params![DeliveryState::Delivered as u8, message_id.as_slice()],
        )?;
        prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
        tx.commit()?;
        Ok(changed == 1)
    }

    pub fn get(&self, message_id: &[u8; 16]) -> Result<Option<QueueItem>, QueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT message_id, packed, peer_addr, state, created_at_ms FROM outgoing WHERE message_id = ?1",
        )?;
        let row = stmt
            .query_row(params![message_id.as_slice()], |r| {
                let id: Vec<u8> = r.get(0)?;
                let mut mid = [0u8; 16];
                if id.len() == 16 {
                    mid.copy_from_slice(&id);
                }
                Ok(QueueItem {
                    message_id: mid,
                    packed_envelope: r.get(1)?,
                    peer_addr: r.get(2)?,
                    state: DeliveryState::from_u8(r.get::<_, u8>(3)?),
                    created_at_ms: r.get::<_, i64>(4)?.max(0) as u64,
                })
            })
            .optional()?;
        Ok(row)
    }

    /// Items still needing send or re-send after crash (Queued or Sent, not Delivered).
    pub fn pending(&self) -> Result<Vec<QueueItem>, QueueError> {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        self.pending_at(now_ms)
    }

    fn pending_at(&self, now_ms: u64) -> Result<Vec<QueueItem>, QueueError> {
        let candidates = {
            let mut stmt = self.conn.prepare(
                "SELECT message_id, packed, peer_addr, state, created_at_ms FROM outgoing
                 WHERE state IN (0, 1) ORDER BY created_at_ms ASC, message_id ASC",
            )?;
            let rows = stmt.query_map([], |r| {
                let id: Vec<u8> = r.get(0)?;
                let mut mid = [0u8; 16];
                if id.len() == 16 {
                    mid.copy_from_slice(&id);
                }
                Ok(QueueItem {
                    message_id: mid,
                    packed_envelope: r.get(1)?,
                    peer_addr: r.get(2)?,
                    state: DeliveryState::from_u8(r.get::<_, u8>(3)?),
                    created_at_ms: r.get::<_, i64>(4)?.max(0) as u64,
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let mut out = Vec::new();
        for item in candidates {
            // Only canonical Raven envelopes are sendable. A malformed legacy
            // row cannot be authenticated or expire safely, so fail it
            // terminally instead of retrying opaque garbage forever. Valid
            // envelopes are pruned at the exact signed-expiry boundary.
            let sendable = Envelope::unpack(&item.packed_envelope)
                .is_some_and(|env| env.message_id == item.message_id && env.expires_at > now_ms);
            if !sendable {
                self.conn.execute(
                    "UPDATE outgoing SET state = ?1
                     WHERE message_id = ?2 AND state IN (0, 1)",
                    params![DeliveryState::Failed as u8, item.message_id.as_slice()],
                )?;
                continue;
            }
            out.push(item);
        }
        self.prune_terminal_rows()?;
        Ok(out)
    }

    /// All outgoing rows (for CLI status). Callers MUST NOT log `packed_envelope`.
    pub fn list_all(&self) -> Result<Vec<QueueItem>, QueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT message_id, packed, peer_addr, state, created_at_ms FROM outgoing
             ORDER BY created_at_ms ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            let id: Vec<u8> = r.get(0)?;
            let mut mid = [0u8; 16];
            if id.len() == 16 {
                mid.copy_from_slice(&id);
            }
            Ok(QueueItem {
                message_id: mid,
                packed_envelope: r.get(1)?,
                peer_addr: r.get(2)?,
                state: DeliveryState::from_u8(r.get::<_, u8>(3)?),
                created_at_ms: r.get::<_, i64>(4)?.max(0) as u64,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Returns true if this inbound message_id was already seen (duplicate).
    pub fn dedup_check_and_insert(
        &self,
        message_id: &[u8; 16],
        now_ms: u64,
    ) -> Result<bool, QueueError> {
        // Insert and retention maintenance share one writer transaction. The
        // existence/capacity/insert decision is serialized, so two processes
        // racing on the same message cannot both report a first delivery. A
        // live replay entry is never evicted merely to admit a newer object;
        // saturation fails closed until an entry reaches its TTL.
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_expired_seen_inbound_on(&tx, now_ms)?;
        let existing: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM seen_inbound WHERE message_id = ?1",
                params![message_id.as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        if existing.is_some() {
            tx.commit()?;
            return Ok(true);
        }
        let count: i64 = tx.query_row("SELECT COUNT(*) FROM seen_inbound", [], |row| row.get(0))?;
        if count as usize >= self.max_seen_rows {
            tx.commit()?;
            return Err(QueueError::SeenCacheFull(self.max_seen_rows));
        }
        tx.execute(
            "INSERT INTO seen_inbound (message_id, seen_at_ms) VALUES (?1, ?2)",
            params![message_id.as_slice(), now_ms.min(i64::MAX as u64) as i64],
        )?;
        tx.commit()?;
        Ok(false)
    }

    fn maintain_bounds(&self, now_ms: u64) -> Result<(), QueueError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
        prune_expired_seen_inbound_on(&tx, now_ms)?;
        tx.commit()?;
        Ok(())
    }

    fn prune_terminal_rows(&self) -> Result<(), QueueError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)?;
        prune_terminal_outgoing_on(&tx, self.max_terminal_rows)?;
        tx.commit()?;
        Ok(())
    }

    fn validate_live_bounds(&self) -> Result<(), QueueError> {
        let (rows, bytes): (i64, i64) = self.conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(length(packed)), 0)
             FROM outgoing WHERE state IN (0, 1)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if rows as usize > self.max_live_rows {
            return Err(QueueError::QueueFull(self.max_live_rows));
        }
        if bytes.max(0) as u64 > self.max_live_bytes {
            return Err(QueueError::QueueByteBudget(self.max_live_bytes));
        }
        let seen: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM seen_inbound", [], |row| row.get(0))?;
        if seen as usize > self.max_seen_rows {
            return Err(QueueError::SeenCacheFull(self.max_seen_rows));
        }
        Ok(())
    }
}

fn system_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn prune_terminal_outgoing_on(
    conn: &Connection,
    retained_rows: usize,
) -> Result<(), rusqlite::Error> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM outgoing WHERE state IN (2, 3)",
        [],
        |row| row.get(0),
    )?;
    let overflow = (count as usize).saturating_sub(retained_rows);
    if overflow == 0 {
        return Ok(());
    }
    conn.execute(
        "DELETE FROM outgoing
         WHERE message_id IN (
           SELECT message_id FROM outgoing
           WHERE state IN (2, 3)
           ORDER BY created_at_ms ASC, message_id ASC
           LIMIT ?1
         )",
        params![overflow.min(i64::MAX as usize) as i64],
    )?;
    Ok(())
}

fn prune_expired_seen_inbound_on(conn: &Connection, now_ms: u64) -> Result<(), rusqlite::Error> {
    if let Some(cutoff) = now_ms.checked_sub(SEEN_INBOUND_TTL_MS) {
        conn.execute(
            "DELETE FROM seen_inbound WHERE seen_at_ms <= ?1",
            params![cutoff.min(i64::MAX as u64) as i64],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::{EnvType, Envelope};
    use crate::identity::Identity;
    use std::sync::{Arc, Barrier};
    use tempfile::tempdir;

    fn packed_test_envelope(message_id: [u8; 16], expires_at: u64) -> Vec<u8> {
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id,
            routing_tag: [0x52; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at,
            hop_limit: 2,
            replication_budget: 1,
            anti_replay_nonce: [0x53; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: b"queue-test".to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&Identity::from_seed(&[0x54; 32]));
        env.pack()
    }

    #[test]
    fn persist_across_reopen() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let mid = [7u8; 16];
        {
            let q = OutgoingQueue::open(&path).unwrap();
            q.enqueue(&QueueItem {
                message_id: mid,
                packed_envelope: packed_test_envelope(mid, u64::MAX),
                peer_addr: "rvn1example".into(),
                state: DeliveryState::Queued,
                created_at_ms: 1,
            })
            .unwrap();
            q.mark_state(&mid, DeliveryState::Sent).unwrap();
        }
        let q = OutgoingQueue::open(&path).unwrap();
        let item = q.get(&mid).unwrap().unwrap();
        assert_eq!(item.state, DeliveryState::Sent);
        assert_eq!(q.pending().unwrap().len(), 1);
        q.mark_state(&mid, DeliveryState::Delivered).unwrap();
        assert!(q.pending().unwrap().is_empty());
    }

    #[test]
    fn dedup() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
        let mid = [1u8; 16];
        assert!(!q.dedup_check_and_insert(&mid, 1).unwrap());
        assert!(q.dedup_check_and_insert(&mid, 2).unwrap());
    }

    #[test]
    fn immutable_enqueue_is_idempotent_and_rejects_id_collision() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
        let item = QueueItem {
            message_id: [9u8; 16],
            packed_envelope: vec![1, 2, 3],
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        };
        q.enqueue(&item).unwrap();
        q.mark_state(&item.message_id, DeliveryState::Sent).unwrap();
        q.enqueue(&item).unwrap();
        assert_eq!(
            q.get(&item.message_id).unwrap().unwrap().state,
            DeliveryState::Sent
        );

        let mut collision = item.clone();
        collision.packed_envelope.push(4);
        assert!(matches!(
            q.enqueue(&collision),
            Err(QueueError::MessageIdCollision)
        ));
    }

    #[test]
    fn delivered_state_never_regresses_and_cas_fires_once() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
        let mid = [8u8; 16];
        q.enqueue(&QueueItem {
            message_id: mid,
            packed_envelope: vec![7],
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        })
        .unwrap();
        assert!(q.mark_delivered_once(&mid).unwrap());
        assert!(!q.mark_delivered_once(&mid).unwrap());
        q.mark_state(&mid, DeliveryState::Sent).unwrap();
        assert_eq!(
            q.get(&mid).unwrap().unwrap().state,
            DeliveryState::Delivered
        );
    }

    #[test]
    fn pending_prunes_signed_envelope_at_exact_expiry_boundary() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x91; 16],
            routing_tag: [0x92; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at: 100,
            hop_limit: 2,
            replication_budget: 1,
            anti_replay_nonce: [0x93; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: b"sealed".to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&Identity::from_seed(&[0x94; 32]));
        q.enqueue(&QueueItem {
            message_id: env.message_id,
            packed_envelope: env.pack(),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        })
        .unwrap();

        assert_eq!(q.pending_at(99).unwrap().len(), 1);
        assert!(q.pending_at(100).unwrap().is_empty());
        assert_eq!(
            q.get(&env.message_id).unwrap().unwrap().state,
            DeliveryState::Failed
        );
        assert!(q.pending_at(101).unwrap().is_empty());
    }

    #[test]
    fn pending_fails_malformed_legacy_row_instead_of_retrying_forever() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
        let mid = [0xA1; 16];
        q.enqueue(&QueueItem {
            message_id: mid,
            packed_envelope: b"RVN1-truncated".to_vec(),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Sent,
            created_at_ms: 1,
        })
        .unwrap();

        assert!(q.pending_at(1).unwrap().is_empty());
        assert_eq!(q.get(&mid).unwrap().unwrap().state, DeliveryState::Failed);
        assert!(q.pending_at(2).unwrap().is_empty());

        let mismatched_mid = [0xA2; 16];
        q.enqueue(&QueueItem {
            message_id: mismatched_mid,
            packed_envelope: packed_test_envelope([0xA3; 16], 100),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 2,
        })
        .unwrap();
        assert!(q.pending_at(2).unwrap().is_empty());
        assert_eq!(
            q.get(&mismatched_mid).unwrap().unwrap().state,
            DeliveryState::Failed
        );
    }

    #[test]
    fn concurrent_exact_enqueue_is_idempotent_across_connections() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let q1 = OutgoingQueue::open(&path).unwrap();
        let q2 = OutgoingQueue::open(&path).unwrap();
        let item = QueueItem {
            message_id: [0xB1; 16],
            packed_envelope: packed_test_envelope([0xB1; 16], u64::MAX),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        };
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let first = item.clone();
        let second = item.clone();
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q1.enqueue(&first)
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.enqueue(&second)
        });
        h1.join().unwrap().unwrap();
        h2.join().unwrap().unwrap();

        let q = OutgoingQueue::open(&path).unwrap();
        let count: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM outgoing", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
        assert_eq!(q.get(&item.message_id).unwrap().unwrap().state, item.state);
    }

    #[test]
    fn concurrent_conflicting_enqueue_reports_collision() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let q1 = OutgoingQueue::open(&path).unwrap();
        let q2 = OutgoingQueue::open(&path).unwrap();
        let first = QueueItem {
            message_id: [0xB2; 16],
            packed_envelope: packed_test_envelope([0xB2; 16], u64::MAX),
            peer_addr: "rvn1alice".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        };
        let mut second = first.clone();
        second.peer_addr = "rvn1mallory".into();
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
                .filter(|result| matches!(result, Err(QueueError::MessageIdCollision)))
                .count(),
            1
        );
    }

    #[test]
    fn concurrent_dedup_has_exactly_one_first_delivery() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let q1 = OutgoingQueue::open(&path).unwrap();
        let q2 = OutgoingQueue::open(&path).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let b1 = Arc::clone(&barrier);
        let b2 = Arc::clone(&barrier);
        let mid = [0xB3; 16];
        let h1 = std::thread::spawn(move || {
            b1.wait();
            q1.dedup_check_and_insert(&mid, 1)
        });
        let h2 = std::thread::spawn(move || {
            b2.wait();
            q2.dedup_check_and_insert(&mid, 1)
        });
        let results = [h1.join().unwrap().unwrap(), h2.join().unwrap().unwrap()];
        assert_eq!(results.iter().filter(|duplicate| !**duplicate).count(), 1);
        assert_eq!(results.iter().filter(|duplicate| **duplicate).count(), 1);
    }

    #[test]
    fn outgoing_and_seen_tables_are_hard_bounded() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let q = OutgoingQueue::open_with_limits(&path, 2, u64::MAX, 1, 3).unwrap();
        for value in 1..=2u8 {
            let mid = [value; 16];
            q.enqueue(&QueueItem {
                message_id: mid,
                packed_envelope: packed_test_envelope(mid, u64::MAX),
                peer_addr: "rvn1peer".into(),
                state: DeliveryState::Queued,
                created_at_ms: value as u64,
            })
            .unwrap();
        }
        let third = QueueItem {
            message_id: [3; 16],
            packed_envelope: packed_test_envelope([3; 16], u64::MAX),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 3,
        };
        assert!(matches!(q.enqueue(&third), Err(QueueError::QueueFull(2))));
        // An exact retry remains idempotent even while admission is full.
        let first = QueueItem {
            message_id: [1; 16],
            packed_envelope: packed_test_envelope([1; 16], u64::MAX),
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        };
        q.enqueue(&first).unwrap();
        q.mark_state(&first.message_id, DeliveryState::Delivered)
            .unwrap();
        q.enqueue(&third).unwrap();

        q.mark_state(&[2; 16], DeliveryState::Failed).unwrap();
        q.mark_state(&[3; 16], DeliveryState::Delivered).unwrap();
        let terminal: i64 = q
            .conn
            .query_row(
                "SELECT COUNT(*) FROM outgoing WHERE state IN (2, 3)",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(terminal, 1);

        for value in 10..=12u8 {
            assert!(!q
                .dedup_check_and_insert(&[value; 16], value as u64)
                .unwrap());
        }
        assert!(matches!(
            q.dedup_check_and_insert(&[13; 16], 13),
            Err(QueueError::SeenCacheFull(3))
        ));
        // Saturation must not evict an unexpired replay record.
        assert!(q.dedup_check_and_insert(&[10; 16], 14).unwrap());
        let seen: i64 = q
            .conn
            .query_row("SELECT COUNT(*) FROM seen_inbound", [], |row| row.get(0))
            .unwrap();
        assert_eq!(seen, 3);
    }

    #[test]
    fn inbound_dedup_expires_at_exact_ttl_boundary() {
        let dir = tempdir().unwrap();
        let q = OutgoingQueue::open_with_limits(&dir.path().join("q.sqlite"), 2, u64::MAX, 1, 3)
            .unwrap();
        let mid = [0xB4; 16];
        assert!(!q.dedup_check_and_insert(&mid, 10).unwrap());
        assert!(q
            .dedup_check_and_insert(&mid, 10 + SEEN_INBOUND_TTL_MS - 1)
            .unwrap());
        assert!(!q
            .dedup_check_and_insert(&mid, 10 + SEEN_INBOUND_TTL_MS)
            .unwrap());
    }

    #[test]
    fn live_byte_budget_and_per_envelope_limit_are_fail_closed() {
        let dir = tempdir().unwrap();
        let q =
            OutgoingQueue::open_with_limits(&dir.path().join("q.sqlite"), 10, 5, 10, 10).unwrap();
        let first = QueueItem {
            message_id: [0xC1; 16],
            packed_envelope: vec![1, 2, 3],
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 1,
        };
        q.enqueue(&first).unwrap();
        let second = QueueItem {
            message_id: [0xC2; 16],
            packed_envelope: vec![4, 5, 6],
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 2,
        };
        assert!(matches!(
            q.enqueue(&second),
            Err(QueueError::QueueByteBudget(5))
        ));

        let oversized = QueueItem {
            message_id: [0xC3; 16],
            packed_envelope: vec![0; MAX_OUTGOING_ENVELOPE_BYTES + 1],
            peer_addr: "rvn1peer".into(),
            state: DeliveryState::Queued,
            created_at_ms: 3,
        };
        assert!(matches!(
            q.enqueue(&oversized),
            Err(QueueError::TooLarge(size)) if size == MAX_OUTGOING_ENVELOPE_BYTES + 1
        ));
    }

    #[test]
    fn reopen_refuses_preexisting_live_rows_above_configured_bounds() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        {
            let q = OutgoingQueue::open_with_limits(&path, 3, 100, 3, 3).unwrap();
            for value in 1..=2u8 {
                q.enqueue(&QueueItem {
                    message_id: [value; 16],
                    packed_envelope: vec![value; 3],
                    peer_addr: "rvn1peer".into(),
                    state: DeliveryState::Queued,
                    created_at_ms: value as u64,
                })
                .unwrap();
            }
        }
        assert!(matches!(
            OutgoingQueue::open_with_limits(&path, 1, 100, 3, 3),
            Err(QueueError::QueueFull(1))
        ));
        assert!(matches!(
            OutgoingQueue::open_with_limits(&path, 3, 5, 3, 3),
            Err(QueueError::QueueByteBudget(5))
        ));
    }

    #[test]
    fn legacy_negative_timestamp_is_never_exposed_as_future_u64() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let q = OutgoingQueue::open(&path).unwrap();
        let mid = [0xC4; 16];
        q.conn
            .execute(
                "INSERT INTO outgoing
                 (message_id, packed, peer_addr, state, created_at_ms)
                 VALUES (?1, ?2, ?3, 2, -1)",
                params![mid.as_slice(), vec![1u8], "rvn1peer"],
            )
            .unwrap();
        assert_eq!(q.get(&mid).unwrap().unwrap().created_at_ms, 0);
        assert_eq!(q.list_all().unwrap()[0].created_at_ms, 0);
    }
}
