//! Integration tests for Raven Bridge V1 (cases 1–8). Mock BLE = TCP length-prefix.

use raven_core::bridge::DropReason;
use raven_core::envelope::{Envelope, EnvType};
use raven_core::forward_queue::{ForwardItem, ForwardQueue, ForwardState};
use raven_core::identity::Identity;
use raven_core::message_router::{InboundEnvelope, MessageRouter, RouterOutcome};
use raven_core::seal::{derive_pairwise_key, seal_message, unseal_message};
use raven_core::transport::TransportKind;
use tempfile::tempdir;

fn now() -> u64 {
    1_700_000_000_000
}

fn make_env(
    signer: &Identity,
    seal_to: &Identity,
    plaintext: &[u8],
    message_id: [u8; 16],
    hop: u8,
    expires_at: u64,
) -> Envelope {
    let key = derive_pairwise_key(&signer.public_key_bytes(), &seal_to.public_key_bytes());
    let sealed = seal_message(
        &key,
        plaintext,
        &signer.address(),
        &seal_to.address(),
        &message_id,
    )
    .unwrap();
    let mut env = Envelope {
        env_type: EnvType::Message as u8,
        flags: 0,
        message_id,
        routing_tag: [7u8; 16],
        dest_device_hint: 0,
        created_at: now(),
        expires_at,
        hop_limit: hop,
        replication_budget: 3,
        anti_replay_nonce: [9u8; 12],
        ratchet_header_ciphertext: vec![],
        message_ciphertext: sealed,
        sender_authentication: vec![],
    };
    env.sign_with(signer);
    env
}

/// 1. BLE→Internet (mock): C-side BLE ingress on B → LAN egress.
#[test]
fn case01_ble_to_internet_forward() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [1u8; 16];
    let env = make_env(&a, &c, b"hello-ac", mid, 8, now() + 60_000);
    let packed = env.pack();
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        local_has_ble: true,
        local_has_internet: true,
        ..Default::default()
    };
    match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: packed.clone(),
            ingress: TransportKind::MockBle,
            previous_hop: "device-c".into(),
            now_ms: now(),
        },
        true,
    ) {
        RouterOutcome::ForwardNow {
            packed: out,
            egress,
            identity,
        } => {
            assert_eq!(egress, TransportKind::Lan);
            assert_eq!(identity.message_id, mid);
            let fwd = Envelope::unpack(&out).unwrap();
            assert_eq!(fwd.message_id, mid);
            assert_eq!(fwd.message_ciphertext, env.message_ciphertext);
            assert!(fwd.verify(&a.public_key_bytes()));
        }
        other => panic!("case1: {other:?}"),
    }
}

/// 2. Internet→BLE reverse.
#[test]
fn case02_internet_to_ble_forward() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [2u8; 16];
    let env = make_env(&a, &c, b"hello-rev", mid, 8, now() + 60_000);
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        local_has_ble: true,
        local_has_internet: true,
        ..Default::default()
    };
    match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: env.pack(),
            ingress: TransportKind::Lan,
            previous_hop: "device-a".into(),
            now_ms: now(),
        },
        true,
    ) {
        RouterOutcome::ForwardNow { egress, identity, .. } => {
            assert_eq!(egress, TransportKind::MockBle);
            assert_eq!(identity.message_id, mid);
        }
        other => panic!("case2: {other:?}"),
    }
}

/// 3. No Internet then later Internet (store-carry-bridge).
#[test]
fn case03_store_carry_bridge() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("f.sqlite");
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [3u8; 16];
    let env = make_env(&a, &c, b"delayed", mid, 8, now() + 60_000);
    {
        let q = ForwardQueue::open(&path).unwrap();
        let router = MessageRouter {
            bridge_enabled: true,
            store_enabled: true,
            endpoint_enabled: false,
            local_has_ble: true,
            local_has_internet: false,
            ..Default::default()
        };
        match router.handle_inbound(
            &q,
            InboundEnvelope {
                packed: env.pack(),
                ingress: TransportKind::MockBle,
                previous_hop: "c".into(),
                now_ms: now(),
            },
            true,
        ) {
            RouterOutcome::QueuedForForward { message_id, .. } => {
                assert_eq!(message_id, mid);
            }
            other => panic!("case3 queue: {other:?}"),
        }
    }
    // Later: internet up — recover pending.
    let q = ForwardQueue::open(&path).unwrap();
    let router = MessageRouter {
        bridge_enabled: true,
        local_has_internet: true,
        local_has_ble: true,
        ..Default::default()
    };
    let pending = router.recover_pending(&q, now() + 1).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].0.message_id, mid);
    assert_eq!(pending[0].0.egress, TransportKind::Lan);
}

/// 4. Dup via BLE+Internet → one delivery (second dropped).
#[test]
fn case04_dup_ble_and_internet() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [4u8; 16];
    let env = make_env(&a, &c, b"once", mid, 8, now() + 60_000);
    let packed = env.pack();
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        ..Default::default()
    };
    let first = router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: packed.clone(),
            ingress: TransportKind::Lan,
            previous_hop: "a".into(),
            now_ms: now(),
        },
        true,
    );
    assert!(matches!(first, RouterOutcome::ForwardNow { .. }));
    let second = router.handle_inbound(
        &q,
        InboundEnvelope {
            packed,
            ingress: TransportKind::MockBle,
            previous_hop: "a-ble".into(),
            now_ms: now() + 1,
        },
        true,
    );
    assert!(matches!(
        second,
        RouterOutcome::Dropped {
            reason: DropReason::Duplicate
        }
    ));
}

/// 5. Tampered ciphertext rejected (signature fails at endpoint verify).
#[test]
fn case05_tampered_ciphertext_rejected() {
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [5u8; 16];
    let mut env = make_env(&a, &c, b"good", mid, 8, now() + 60_000);
    assert!(env.verify(&a.public_key_bytes()));
    // Flip a ciphertext byte — signing covers hash of ciphertext → verify fails.
    if let Some(b) = env.message_ciphertext.first_mut() {
        *b ^= 0xff;
    }
    assert!(
        !env.verify(&a.public_key_bytes()),
        "tampered body must fail envelope auth"
    );
}

/// 6. Replay rejected.
#[test]
fn case06_replay_rejected() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [6u8; 16];
    let packed = make_env(&a, &c, b"replay", mid, 8, now() + 60_000).pack();
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        ..Default::default()
    };
    let _ = router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: packed.clone(),
            ingress: TransportKind::Lan,
            previous_hop: "a".into(),
            now_ms: now(),
        },
        true,
    );
    let replay = router.handle_inbound(
        &q,
        InboundEnvelope {
            packed,
            ingress: TransportKind::Lan,
            previous_hop: "a".into(),
            now_ms: now() + 5,
        },
        true,
    );
    assert!(matches!(
        replay,
        RouterOutcome::Dropped {
            reason: DropReason::Duplicate
        }
    ));
}

/// 7. Crash after receive → queue recovers.
#[test]
fn case07_crash_recover_queue() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("f.sqlite");
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [7u8; 16];
    let packed = make_env(&a, &c, b"custody", mid, 8, now() + 60_000).pack();
    {
        let q = ForwardQueue::open(&path).unwrap();
        q.enqueue(&ForwardItem {
            message_id: mid,
            packed_envelope: packed.clone(),
            ingress: TransportKind::MockBle,
            egress: TransportKind::Lan,
            state: ForwardState::Queued,
            created_at_ms: now(),
            expires_at_ms: now() + 60_000,
            previous_hop: "c".into(),
        })
        .unwrap();
    }
    // Simulate process restart.
    let q = ForwardQueue::open(&path).unwrap();
    let router = MessageRouter::default();
    let recovered = router.recover_pending(&q, now() + 10).unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].0.packed_envelope, packed);
    assert_eq!(recovered[0].1.message_id, mid);
}

/// 8. Expired while offline → never forward after expiry.
#[test]
fn case08_expired_never_forward() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("f.sqlite");
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [8u8; 16];
    let expires = now() + 100;
    let packed = make_env(&a, &c, b"stale", mid, 8, expires).pack();
    {
        let q = ForwardQueue::open(&path).unwrap();
        let router = MessageRouter {
            bridge_enabled: true,
            store_enabled: true,
            endpoint_enabled: false,
            local_has_internet: false,
            local_has_ble: true,
            ..Default::default()
        };
        let _ = router.handle_inbound(
            &q,
            InboundEnvelope {
                packed,
                ingress: TransportKind::MockBle,
                previous_hop: "c".into(),
                now_ms: now(),
            },
            true,
        );
        assert_eq!(q.count_pending().unwrap(), 1);
    }
    let q = ForwardQueue::open(&path).unwrap();
    let router = MessageRouter {
        local_has_internet: true,
        ..Default::default()
    };
    let after_expiry = expires + 1;
    let recovered = router.recover_pending(&q, after_expiry).unwrap();
    assert!(recovered.is_empty(), "expired must not forward");
    let item = q.get(&mid).unwrap().unwrap();
    assert_eq!(item.state, ForwardState::Expired);
}

/// Endpoint can still unseal A↔C after bridge hop (E2EE preserved).
#[test]
fn e2ee_survives_bridge_hop() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [99u8; 16];
    let env = make_env(&a, &c, b"secret-e2ee", mid, 8, now() + 60_000);
    let body_before = env.message_ciphertext.clone();
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        ..Default::default()
    };
    let out = match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: env.pack(),
            ingress: TransportKind::Lan,
            previous_hop: "a".into(),
            now_ms: now(),
        },
        true,
    ) {
        RouterOutcome::ForwardNow { packed, .. } => packed,
        other => panic!("{other:?}"),
    };
    let fwd = Envelope::unpack(&out).unwrap();
    assert_eq!(fwd.message_ciphertext, body_before);
    let key = derive_pairwise_key(&c.public_key_bytes(), &a.public_key_bytes());
    let pt = unseal_message(
        &key,
        &fwd.message_ciphertext,
        &a.address(),
        &c.address(),
        &mid,
    )
    .unwrap();
    assert_eq!(pt, b"secret-e2ee");
}

/// 9. Per-peer rate limit drops flood from one hop; other peers still forward.
#[test]
fn case09_per_peer_rate_limit() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open_with_peer_limits(
        &dir.path().join("f.sqlite"),
        512,
        1_048_576,
        64,
        2, // only 2 enqueues / window from same peer
        256_000,
        60_000,
    )
    .unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        local_has_ble: true,
        local_has_internet: true,
        ..Default::default()
    };
    let mut outcomes = Vec::new();
    for i in 0u8..3 {
        let mut mid = [10u8; 16];
        mid[15] = i;
        let packed = make_env(&a, &c, b"flood", mid, 8, now() + 60_000).pack();
        outcomes.push(router.handle_inbound(
            &q,
            InboundEnvelope {
                packed,
                ingress: TransportKind::Lan,
                previous_hop: "noisy-peer".into(),
                now_ms: now() + i as u64,
            },
            true,
        ));
    }
    assert!(matches!(outcomes[0], RouterOutcome::ForwardNow { .. }));
    assert!(matches!(outcomes[1], RouterOutcome::ForwardNow { .. }));
    assert!(matches!(
        outcomes[2],
        RouterOutcome::Dropped {
            reason: DropReason::RateLimited
        }
    ));
    // Different peer still accepted.
    let mid = [11u8; 16];
    let packed = make_env(&a, &c, b"other", mid, 8, now() + 60_000).pack();
    match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed,
            ingress: TransportKind::Lan,
            previous_hop: "quiet-peer".into(),
            now_ms: now() + 10,
        },
        true,
    ) {
        RouterOutcome::ForwardNow { .. } => {}
        other => panic!("quiet peer should forward: {other:?}"),
    }
}

fn make_ack(signer: &Identity, acked_message_id: [u8; 16]) -> Envelope {
    let mut body = Vec::new();
    body.extend_from_slice(&acked_message_id);
    body.push(1); // STATUS_DELIVERED
    body.extend_from_slice(&[0x11u8; 12]);
    body.extend_from_slice(&now().to_be_bytes());
    body.extend_from_slice(&[0x22u8; 64]); // opaque sig bytes for relay (not verified here)
    let mut mid = [0xACu8; 16];
    mid[0] = acked_message_id[0];
    let mut env = Envelope {
        env_type: EnvType::Ack as u8,
        flags: 0,
        message_id: mid,
        routing_tag: [8u8; 16],
        dest_device_hint: 0,
        created_at: now(),
        expires_at: now() + 60_000,
        hop_limit: 8,
        replication_budget: 1,
        anti_replay_nonce: [4u8; 12],
        ratchet_header_ciphertext: vec![],
        message_ciphertext: body,
        sender_authentication: vec![],
    };
    env.sign_with(signer);
    env
}

/// 10. Recipient ACK reverse: BLE→LAN on B; opaque body preserved; A mid peeked.
#[test]
fn case10_ack_reverse_relay_opaque() {
    use raven_core::opaque_acked_message_id;
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let c = Identity::generate();
    let acked = [0x10u8; 16];
    let ack = make_ack(&c, acked);
    let packed = ack.pack();
    assert_eq!(opaque_acked_message_id(&packed), Some(acked));

    let router = MessageRouter {
        bridge_enabled: true,
        endpoint_enabled: false,
        local_has_ble: true,
        local_has_internet: true,
        ..Default::default()
    };
    match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: packed.clone(),
            ingress: TransportKind::MockBle,
            previous_hop: "device-c".into(),
            now_ms: now(),
        },
        true,
    ) {
        RouterOutcome::ForwardNow {
            packed: out,
            egress,
            identity,
        } => {
            assert_eq!(egress, TransportKind::Lan);
            assert_eq!(identity.message_id, ack.message_id);
            let fwd = Envelope::unpack(&out).unwrap();
            assert_eq!(fwd.env_type, EnvType::Ack as u8);
            assert_eq!(fwd.message_ciphertext, ack.message_ciphertext);
            assert_eq!(opaque_acked_message_id(&out), Some(acked));
            assert!(fwd.verify(&c.public_key_bytes()));
        }
        other => panic!("case10: {other:?}"),
    }
}

/// Destination ingest: when local is endpoint (not forced bridge), DeliverToEndpoint.
#[test]
fn case10b_destination_deliver_to_endpoint() {
    let dir = tempdir().unwrap();
    let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
    let a = Identity::generate();
    let c = Identity::generate();
    let mid = [0xCCu8; 16];
    let env = make_env(&a, &c, b"for-c", mid, 8, now() + 60_000);
    let router = MessageRouter {
        bridge_enabled: false,
        endpoint_enabled: true,
        ..Default::default()
    };
    match router.handle_inbound(
        &q,
        InboundEnvelope {
            packed: env.pack(),
            ingress: TransportKind::MockBle,
            previous_hop: "b".into(),
            now_ms: now(),
        },
        false,
    ) {
        RouterOutcome::DeliverToEndpoint { identity, packed } => {
            assert_eq!(identity.message_id, mid);
            let got = Envelope::unpack(&packed).unwrap();
            assert_eq!(got.message_ciphertext, env.message_ciphertext);
        }
        other => panic!("case10b: {other:?}"),
    }
}
