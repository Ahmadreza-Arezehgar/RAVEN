//! Domain-separated digests (design §2.3).

use sha2::{Digest, Sha256};

const DOMAIN_STATE: &[u8] = b"ATSAM/v2/full-braid/state";
const DOMAIN_INPUT: &[u8] = b"ATSAM/v2/full-braid/input";
const DOMAIN_EXECUTION: &[u8] = b"ATSAM/v2/full-braid/execution";
const DOMAIN_OUTPUT: &[u8] = b"ATSAM/v2/full-braid/output";
const DOMAIN_SEND_SOURCE: &[u8] = b"ATSAM/v2/braid-send-source";
const DOMAIN_BRAID_OBJECT: &[u8] = b"ATSAM/v2/braid-object";
const DOMAIN_BRAID_CHUNK: &[u8] = b"ATSAM/v2/braid-chunk";
const DOMAIN_TRANSITION_ID: &[u8] = b"ATSAM/v2/full-braid/transition-id";

/// `SHA-256("ATSAM/v2/full-braid/state" || schema_rev_u16be || RVFB1_bytes)`.
pub fn state_digest(schema_rev: u16, rvfb1_bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_STATE);
    h.update(schema_rev.to_be_bytes());
    h.update(rvfb1_bytes);
    h.finalize().into()
}

/// `SHA-256("ATSAM/v2/full-braid/input" || RVBI1_bytes)`.
pub fn input_digest(rvbi1_bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_INPUT);
    h.update(rvbi1_bytes);
    h.finalize().into()
}

/// `SHA-256("ATSAM/v2/full-braid/execution" || u32be_len(RVBI1) || RVBI1 || u32be_len(RVBE1) || RVBE1)`.
pub fn execution_digest(rvbi1_bytes: &[u8], rvbe1_bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_EXECUTION);
    h.update((rvbi1_bytes.len() as u32).to_be_bytes());
    h.update(rvbi1_bytes);
    h.update((rvbe1_bytes.len() as u32).to_be_bytes());
    h.update(rvbe1_bytes);
    h.finalize().into()
}

/// `SHA-256("ATSAM/v2/full-braid/output" || RVBO1_bytes)`.
pub fn output_digest(rvbo1_bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_OUTPUT);
    h.update(rvbo1_bytes);
    h.finalize().into()
}

/// `SHA-256(endpoint_object_bytes)`.
pub fn object_digest(endpoint_object_bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(endpoint_object_bytes).into()
}

/// `SHA-256("ATSAM/v2/braid-send-source" || source_bytes)`.
pub fn send_source_digest(source_bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_SEND_SOURCE);
    h.update(source_bytes);
    h.finalize().into()
}

/// `SHA-256("ATSAM/v2/braid-object" || session_id || dir || epoch || source_kind || source_bytes)`.
pub fn braid_object_digest(
    session_id: &[u8; 32],
    direction: u8,
    epoch: u64,
    source_kind: u8,
    source_bytes: &[u8],
) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_BRAID_OBJECT);
    h.update(session_id);
    h.update([direction]);
    h.update(epoch.to_be_bytes());
    h.update([source_kind]);
    h.update(source_bytes);
    h.finalize().into()
}

/// Chunk binding digest (design §4.1).
pub fn binding_digest(
    direction: u8,
    epoch: u64,
    chunk_type: u8,
    index: u32,
    payload: &[u8],
    session_id: &[u8; 32],
) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_BRAID_CHUNK);
    h.update([direction]);
    h.update(epoch.to_be_bytes());
    h.update([chunk_type]);
    h.update(index.to_be_bytes());
    h.update(payload);
    h.update(session_id);
    h.finalize().into()
}

/// Transition id digest (design §2.3).
pub fn transition_id_digest(
    session_id: &[u8; 32],
    role: u8,
    direction: u8,
    generation: u64,
    execution_digest: &[u8; 32],
    before_state_digest: &[u8; 32],
) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DOMAIN_TRANSITION_ID);
    h.update(session_id);
    h.update([role]);
    h.update([direction]);
    h.update(generation.to_be_bytes());
    h.update(execution_digest);
    h.update(before_state_digest);
    h.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_digest_includes_schema_rev() {
        let bytes = b"rvfb1-body";
        let d1 = state_digest(1, bytes);
        let d2 = state_digest(2, bytes);
        assert_ne!(d1, d2);
        assert_ne!(d1, state_digest(1, b"other"));
    }

    #[test]
    fn execution_digest_length_delimited() {
        let rvbi = b"rvbi";
        let rvbe = b"rvbe";
        let d = execution_digest(rvbi, rvbe);
        let mut h = Sha256::new();
        h.update(DOMAIN_EXECUTION);
        h.update((rvbi.len() as u32).to_be_bytes());
        h.update(rvbi);
        h.update((rvbe.len() as u32).to_be_bytes());
        h.update(rvbe);
        let expected: [u8; 32] = h.finalize().into();
        assert_eq!(d, expected);
    }

    #[test]
    fn binding_digest_domain() {
        let sid = [0x11u8; 32];
        let d = binding_digest(0, 1, 1, 0, &[0xAA; 32], &sid);
        assert_ne!(d, [0u8; 32]);
        assert_ne!(d, binding_digest(1, 1, 1, 0, &[0xAA; 32], &sid));
    }

    #[test]
    fn transition_id_digest_ordering() {
        let sid = [0x22u8; 32];
        let exec = [0x33u8; 32];
        let before = [0x44u8; 32];
        let d = transition_id_digest(&sid, 0, 0, 0, &exec, &before);
        assert_ne!(d, transition_id_digest(&sid, 1, 0, 0, &exec, &before));
    }
}
