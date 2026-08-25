//! Parser fuzz smoke + ANSI/bidi sanitization + opt-in scale hook.

use raven_core::envelope::Envelope;
use raven_core::internet::{deframe_prefix, frame, unpack_verify_hello};
use raven_core::sanitize::{had_dangerous_controls, sanitize_terminal_text};
use raven_core::store_object::StoreObject;

/// Deterministic byte mutations — CI-safe fuzz smoke (not a long campaign).
#[test]
fn fuzz_smoke_envelope_and_frames() {
    let seeds: &[&[u8]] = &[
        &[],
        b"RVN1",
        b"RVN1\x01",
        b"RSO1",
        b"RIH1",
        &[0xff; 8],
        &[0x00; 200],
        b"\x1b[31mRVN1",
    ];
    let mut corpus = Vec::new();
    for s in seeds {
        corpus.push(s.to_vec());
        // Mutations
        let mut m = s.to_vec();
        if !m.is_empty() {
            m[0] ^= 0x5a;
            corpus.push(m.clone());
            m.push(0xaa);
            corpus.push(m);
        }
        let mut big = s.to_vec();
        big.extend(std::iter::repeat_n(0x41, 4096));
        corpus.push(big);
    }
    // Also mutate a well-formed framed payload.
    if let Ok(f) = frame(b"RVN1demo") {
        corpus.push(f.clone());
        let mut t = f;
        if t.len() > 5 {
            t[5] ^= 0xff;
        }
        corpus.push(t);
    }

    for c in &corpus {
        let _ = Envelope::unpack(c);
        let _ = StoreObject::unpack(c);
        let _ = unpack_verify_hello(c);
        let _ = deframe_prefix(c);
    }
}

#[test]
fn ansi_and_bidi_sanitization() {
    let nasty = "\u{1b}[32malice\u{202E}bob\u{1b}[0m";
    assert!(had_dangerous_controls(nasty));
    let clean = sanitize_terminal_text(nasty);
    assert_eq!(clean, "alicebob");
    assert!(!clean.contains('\u{1b}'));
    assert!(!clean.contains('\u{202E}'));
}

#[test]
fn scale_1k_queue_enqueue_dedup_ack() {
    // Strengthened 1k subset of the 10k reliability script — always runs in CI.
    use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
    let dir = tempfile::tempdir().unwrap();
    let q = OutgoingQueue::open(&dir.path().join("q.sqlite")).unwrap();
    const N: u32 = 1_000;
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
    assert_eq!(q.pending().unwrap().len(), N as usize);
    for i in 0..N {
        let mut mid = [0u8; 16];
        mid[..4].copy_from_slice(&i.to_be_bytes());
        q.mark_state(&mid, DeliveryState::Delivered).unwrap();
    }
    assert!(q.pending().unwrap().is_empty());
}
