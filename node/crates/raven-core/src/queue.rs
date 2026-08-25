//! Persistent outgoing queue (SQLite). Delivery advances only on signed ACK.

use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use thiserror::Error;

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
}

pub struct OutgoingQueue {
    conn: Connection,
}

impl OutgoingQueue {
    pub fn open(path: &Path) -> Result<Self, QueueError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS outgoing (
               message_id BLOB PRIMARY KEY NOT NULL,
               packed BLOB NOT NULL,
               peer_addr TEXT NOT NULL,
               state INTEGER NOT NULL,
               created_at_ms INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS seen_inbound (
               message_id BLOB PRIMARY KEY NOT NULL,
               seen_at_ms INTEGER NOT NULL
             );",
        )?;
        Ok(Self { conn })
    }

    pub fn enqueue(&self, item: &QueueItem) -> Result<(), QueueError> {
        if item.message_id.len() != 16 {
            return Err(QueueError::BadId);
        }
        // Retries of the exact same immutable object are idempotent and must
        // not reset delivery state. Reusing an ID for different ciphertext or
        // a different recipient is a hard local integrity failure.
        let existing: Option<(Vec<u8>, String)> = self
            .conn
            .query_row(
                "SELECT packed, peer_addr FROM outgoing WHERE message_id = ?1",
                params![item.message_id.as_slice()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((packed, peer_addr)) = existing {
            if packed == item.packed_envelope && peer_addr == item.peer_addr {
                return Ok(());
            }
            return Err(QueueError::MessageIdCollision);
        }
        self.conn.execute(
            "INSERT INTO outgoing (message_id, packed, peer_addr, state, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                item.message_id.as_slice(),
                item.packed_envelope,
                item.peer_addr,
                item.state as u8,
                item.created_at_ms as i64
            ],
        )?;
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
        self.conn
            .execute(&sql, params![state as u8, message_id.as_slice()])?;
        Ok(())
    }

    /// Compare-and-set used by authenticated receipt handling. Returns true
    /// exactly once for a live Queued/Sent row; duplicates and terminal rows
    /// are no-ops, which prevents duplicate UI delivery events.
    pub fn mark_delivered_once(&self, message_id: &[u8; 16]) -> Result<bool, QueueError> {
        let changed = self.conn.execute(
            "UPDATE outgoing SET state = ?1
             WHERE message_id = ?2 AND state IN (0, 1)",
            params![DeliveryState::Delivered as u8, message_id.as_slice()],
        )?;
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
                    created_at_ms: r.get::<_, i64>(4)? as u64,
                })
            })
            .optional()?;
        Ok(row)
    }

    /// Items still needing send or re-send after crash (Queued or Sent, not Delivered).
    pub fn pending(&self) -> Result<Vec<QueueItem>, QueueError> {
        let mut stmt = self.conn.prepare(
            "SELECT message_id, packed, peer_addr, state, created_at_ms FROM outgoing
             WHERE state IN (0, 1) ORDER BY created_at_ms ASC",
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
                created_at_ms: r.get::<_, i64>(4)? as u64,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
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
                created_at_ms: r.get::<_, i64>(4)? as u64,
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
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM seen_inbound WHERE message_id = ?1",
                params![message_id.as_slice()],
                |r| r.get(0),
            )
            .optional()?;
        if existing.is_some() {
            return Ok(true);
        }
        self.conn.execute(
            "INSERT INTO seen_inbound (message_id, seen_at_ms) VALUES (?1, ?2)",
            params![message_id.as_slice(), now_ms as i64],
        )?;
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn persist_across_reopen() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("q.sqlite");
        let mid = [7u8; 16];
        {
            let q = OutgoingQueue::open(&path).unwrap();
            q.enqueue(&QueueItem {
                message_id: mid,
                packed_envelope: vec![1, 2, 3],
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
}
