//! Opt-in 10k message reliability (ignored by default — run via reliability_10k.sh).

use raven_core::envelope::{EnvType, Envelope};
use raven_core::identity::Identity;
use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use std::time::Instant;

fn packed_queue_envelope(signer: &Identity, message_id: [u8; 16], sequence: u32) -> Vec<u8> {
    let sequence_bytes = sequence.to_be_bytes();
    let mut nonce = [0u8; 12];
    nonce[..sequence_bytes.len()].copy_from_slice(&sequence_bytes);
    let mut env = Envelope {
        env_type: EnvType::Message as u8,
        flags: 0,
        message_id,
        routing_tag: [0x52; 16],
        dest_device_hint: 0,
        created_at: 1,
        expires_at: u64::MAX,
        hop_limit: 8,
        replication_budget: 3,
        anti_replay_nonce: nonce,
        ratchet_header_ciphertext: vec![],
        message_ciphertext: sequence_bytes.to_vec(),
        sender_authentication: vec![],
    };
    env.sign_with(signer);
    env.pack()
}

#[test]
#[ignore]
fn reliability_10k_enqueue_dedup_ack() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("q.sqlite");
    let q = OutgoingQueue::open(&path).unwrap();
    let t0 = Instant::now();
    let signer = Identity::from_seed(&[0x33; 32]);
    const N: u32 = 10_000;
    for i in 0..N {
        let mut mid = [0u8; 16];
        mid[..4].copy_from_slice(&i.to_be_bytes());
        q.enqueue(&QueueItem {
            message_id: mid,
            packed_envelope: packed_queue_envelope(&signer, mid, i),
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
