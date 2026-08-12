//! Opt-in 10k message reliability (ignored by default — run via reliability_10k.sh).

use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use std::time::Instant;

#[test]
#[ignore]
fn reliability_10k_enqueue_dedup_ack() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("q.sqlite");
    let q = OutgoingQueue::open(&path).unwrap();
    let t0 = Instant::now();
    const N: u32 = 10_000;
    for i in 0..N {
        let mut mid = [0u8; 16];
        mid[..4].copy_from_slice(&i.to_be_bytes());
        q.enqueue(&QueueItem {
            message_id: mid,
            packed_envelope: {
                let mut v = vec![0x52, 0x56, 0x4E, 0x31, 1];
                v.extend_from_slice(&i.to_be_bytes());
                v
            },
            peer_addr: format!("peer-{}", i % 17),
            state: DeliveryState::Queued,
            created_at_ms: i as u64,
        })
        .unwrap();
        if i % 2 == 0 {
            q.mark_state(&mid, DeliveryState::Sent).unwrap();
        }
        assert!(!q.dedup_check_and_insert(&mid, i as u64).unwrap());
        assert!(q.dedup_check_and_insert(&mid, i as u64 + 1).unwrap());
    }
    let pending = q.pending().unwrap();
    assert_eq!(pending.len(), N as usize);
    for i in 0..N {
        let mut mid = [0u8; 16];
        mid[..4].copy_from_slice(&i.to_be_bytes());
        q.mark_state(&mid, DeliveryState::Delivered).unwrap();
    }
    assert!(q.pending().unwrap().is_empty());
    eprintln!("reliability_10k ok in {:?}", t0.elapsed());
}
