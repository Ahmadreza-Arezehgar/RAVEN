//! Reliability: dedup, queue restart, malformed frames, OOO message_ids.

use raven_core::envelope::{EnvType, Envelope};
use raven_core::identity::Identity;
use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use tempfile::tempdir;

fn packed_test_envelope(signer: &Identity, message_id: [u8; 16]) -> Vec<u8> {
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
        anti_replay_nonce: [0x91; 12],
        ratchet_header_ciphertext: vec![],
        message_ciphertext: b"restart-fixture".to_vec(),
        sender_authentication: vec![],
    };
    env.sign_with(signer);
    env.pack()
}

#[test]
fn restart_mid_queue_then_ack() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("q.sqlite");
    let mid = [3u8; 16];
    let signer = Identity::from_seed(&[0x31; 32]);
    {
        let q = OutgoingQueue::open(&path).unwrap();
        q.enqueue(&QueueItem {
            message_id: mid,
            packed_envelope: packed_test_envelope(&signer, mid),
            peer_addr: "rvn1examplepeer000000000000000000000".into(),
            state: DeliveryState::Queued,
            created_at_ms: 10,
        })
        .unwrap();
        q.mark_state(&mid, DeliveryState::Sent).unwrap();
    }
    // Crash window: Sent but not Delivered
    let q = OutgoingQueue::open(&path).unwrap();
    let pending = q.pending().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].state, DeliveryState::Sent);
    q.mark_state(&mid, DeliveryState::Delivered).unwrap();
    assert!(q.pending().unwrap().is_empty());
}

#[test]
fn duplicate_inbound_dedup() {
    let dir = tempdir().unwrap();
    let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
    let mid = [9u8; 16];
    assert!(!q.dedup_check_and_insert(&mid, 1).unwrap());
    assert!(q.dedup_check_and_insert(&mid, 2).unwrap());
    assert!(q.dedup_check_and_insert(&mid, 3).unwrap());
}

#[test]
fn malformed_and_truncated_do_not_panic() {
    let cases: &[&[u8]] = &[
        &[],
        &[0xff, 0xff],
        b"RVN1",
        &[0x52, 0x56, 0x4E, 0x31, 0x01],
        &[0u8; 86],
    ];
    for c in cases {
        let _ = Envelope::unpack(c);
    }
    let mut almost = vec![0u8; 120];
    almost[0..4].copy_from_slice(b"RVN1");
    almost[4] = 1;
    almost[78] = 0x00;
    almost[79] = 0x10; // hdr 16
    almost[80] = 0;
    almost[81] = 0;
    almost[82] = 0;
    almost[83] = 0x10; // body 16 — total claim exceeds buffer
    let _ = Envelope::unpack(&almost);
}

#[test]
fn out_of_order_message_ids_still_dedup_independently() {
    let dir = tempdir().unwrap();
    let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
    let a = [1u8; 16];
    let b = [2u8; 16];
    // Arrive B before A
    assert!(!q.dedup_check_and_insert(&b, 1).unwrap());
    assert!(!q.dedup_check_and_insert(&a, 2).unwrap());
    assert!(q.dedup_check_and_insert(&b, 3).unwrap());
}
