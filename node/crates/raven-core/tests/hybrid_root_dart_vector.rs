//! Interop vector: the Dart side (AtsamPairing.deriveHybridRoot) must derive
//! exactly this root for the same fixed inputs. Run:
//!   cargo test -p raven-core --test hybrid_root_dart_vector -- --nocapture

use raven_core::atsam_root::{derive_root, transcript_hash};

#[test]
fn prints_and_locks_hybrid_root_vector() {
    let zx = [0xA1u8; 32];
    let zpq = [0xB2u8; 32];
    let th = transcript_hash(b"hybrid-vector-001");
    let root = derive_root(&zx, &zpq, &th);
    println!("HYBRID_ROOT_VECTOR_HEX={}", hex::encode(root));
    // Locked once generated; change only with a new vector id.
    assert_eq!(
        hex::encode(root),
        "cc85c20f4d320e3f1cb55f544968550e7fec7b055598db546582c4261e03394f"
    );
}
