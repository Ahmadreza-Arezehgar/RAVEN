//! Opaque RavenEnvelopeV1 bridge / store-carry-forward helpers.
//!
//! Design constraints (practical DTN lessons — not BPv7 wire format):
//! - Bundles/envelopes are **opaque** at relays (RFC 9171 / MIT DTN store-carry-forward).
//! - Hop budget bounds loops (BPv7 Hop Count Block lesson: limit + count safety).
//! - Replication budget bounds fan-out (Spray-and-Wait / binary spray spirit).
//! - Lifetime/`expires_at` drops stale custody (BP lifetime).
//! - End-to-end ACK only from the true recipient — relays MUST NOT forge Delivered.
//! - Relays may decrement mutable fields (`hop_limit`, `replication_budget`) only;
//!   `message_id`, ciphertext, and `sender_authentication` stay byte-identical.

use sha2::{Digest, Sha256};

use crate::envelope::{EnvType, Envelope};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeRole {
    /// True endpoint: may decrypt (if capable) and emit recipient ACK.
    Endpoint,
    /// Relay: forward opaque bytes only; never plaintext; never recipient ACK.
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    Expired,
    HopExhausted,
    ReplicationExhausted,
    Duplicate,
    Malformed,
    UnsupportedType,
    /// Per-peer enqueue / pending / byte budget exceeded (abuse protection).
    RateLimited,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeAction {
    /// Local endpoint should handle (decrypt/ACK if Message).
    DeliverLocal,
    /// Relay should store/forward this packed envelope (hop already applied).
    Forward {
        packed: Vec<u8>,
    },
    Drop {
        reason: DropReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeIdentity {
    pub message_id: [u8; 16],
    pub body_sha256: [u8; 32],
    pub auth_sha256: [u8; 32],
    /// Stable across compliant hop mutations and safe for unauthenticated
    /// relay dedup. Unlike `message_id`, this value is not attacker-selected
    /// independently of the signed object bytes.
    pub object_digest: [u8; 32],
}

/// Digest of the immutable, purportedly authenticated envelope object.
///
/// Relays may not know the sender key, so this is *not* proof of authenticity.
/// It is only a bounded replay-cache key that lets a later valid envelope with
/// the same attacker-visible `message_id` remain independently admissible.
pub fn authenticated_object_digest(env: &Envelope) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"rvn1/relay-object-digest/v1");
    h.update(env.signing_bytes());
    h.update(&env.sender_authentication);
    h.finalize().into()
}

impl EnvelopeIdentity {
    pub fn from_envelope(env: &Envelope) -> Self {
        let mut body = [0u8; 32];
        body.copy_from_slice(&Sha256::digest(&env.message_ciphertext));
        let mut auth = [0u8; 32];
        auth.copy_from_slice(&Sha256::digest(&env.sender_authentication));
        Self {
            message_id: env.message_id,
            body_sha256: body,
            auth_sha256: auth,
            object_digest: authenticated_object_digest(env),
        }
    }

    /// True when message_id + ciphertext + sender_authentication match (relay-safe).
    pub fn matches_preserved(&self, other: &Self) -> bool {
        self.message_id == other.message_id
            && self.body_sha256 == other.body_sha256
            && self.auth_sha256 == other.auth_sha256
            && self.object_digest == other.object_digest
    }
}

/// Decide what a node should do with an inbound packed RavenEnvelopeV1.
///
/// `is_duplicate` is supplied by the caller (persistent dedup). Relays never
/// return `DeliverLocal` for Message/Ack — they forward or drop.
pub fn decide(packed: &[u8], role: BridgeRole, now_ms: u64, is_duplicate: bool) -> BridgeAction {
    let Some(env) = Envelope::unpack(packed) else {
        return BridgeAction::Drop {
            reason: DropReason::Malformed,
        };
    };
    if is_duplicate {
        return BridgeAction::Drop {
            reason: DropReason::Duplicate,
        };
    }
    if now_ms >= env.expires_at {
        return BridgeAction::Drop {
            reason: DropReason::Expired,
        };
    }
    match EnvType::from_u8(env.env_type) {
        Some(EnvType::Message) | Some(EnvType::Ack) => match role {
            BridgeRole::Endpoint => BridgeAction::DeliverLocal,
            BridgeRole::Relay => match prepare_forward(env) {
                Ok(fwd) => BridgeAction::Forward { packed: fwd.pack() },
                Err(reason) => BridgeAction::Drop { reason },
            },
        },
        Some(_) => BridgeAction::Drop {
            reason: DropReason::UnsupportedType,
        },
        None => BridgeAction::Drop {
            reason: DropReason::Malformed,
        },
    }
}

/// Decrement hop / consume one replication token. Signature stays valid because
/// those fields are zeroed in `signing_bytes`. Ciphertext and auth unchanged.
pub fn prepare_forward(mut env: Envelope) -> Result<Envelope, DropReason> {
    if env.hop_limit == 0 {
        return Err(DropReason::HopExhausted);
    }
    if env.replication_budget == 0 {
        return Err(DropReason::ReplicationExhausted);
    }
    env.hop_limit = env.hop_limit.saturating_sub(1);
    // Spray-and-Wait spirit: each forward consumes one replica token.
    env.replication_budget = env.replication_budget.saturating_sub(1);
    Ok(env)
}

/// Binary spray helper: split remaining replication budget (kept, given).
/// Used when a relay has multiple next hops; A–B–C single-path uses `prepare_forward`.
pub fn split_replication(budget: u8) -> (u8, u8) {
    if budget <= 1 {
        return (0, budget);
    }
    let given = budget / 2;
    let kept = budget - given;
    (kept, given)
}

/// Multi-role classification: destination wins over bridge so B never steals C's body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MultiRoleDisposition {
    DeliverToEndpoint,
    BridgeForward,
    AckRelay,
    Drop,
}

pub fn classify_multi_role(
    env_type: u8,
    local_is_destination: bool,
    bridge_enabled: bool,
) -> MultiRoleDisposition {
    match EnvType::from_u8(env_type) {
        Some(EnvType::Ack) if bridge_enabled => MultiRoleDisposition::AckRelay,
        Some(EnvType::Ack) => MultiRoleDisposition::DeliverToEndpoint,
        Some(EnvType::Message) if local_is_destination => MultiRoleDisposition::DeliverToEndpoint,
        Some(EnvType::Message) if bridge_enabled => MultiRoleDisposition::BridgeForward,
        Some(EnvType::Message) => MultiRoleDisposition::DeliverToEndpoint,
        Some(_) | None => MultiRoleDisposition::Drop,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn sample_env(hop: u8, repl: u8, expires: u64) -> Envelope {
        let id = Identity::generate();
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [9u8; 16],
            routing_tag: [3u8; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at: expires,
            hop_limit: hop,
            replication_budget: repl,
            anti_replay_nonce: [1u8; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: b"opaque-sealed-body".to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&id);
        env
    }

    #[test]
    fn relay_forwards_preserving_identity() {
        let env = sample_env(4, 3, u64::MAX);
        let before = EnvelopeIdentity::from_envelope(&env);
        let packed = env.pack();
        match decide(&packed, BridgeRole::Relay, 10, false) {
            BridgeAction::Forward { packed: out } => {
                let fwd = Envelope::unpack(&out).unwrap();
                let after = EnvelopeIdentity::from_envelope(&fwd);
                assert!(before.matches_preserved(&after));
                assert_eq!(fwd.hop_limit, 3);
                assert_eq!(fwd.replication_budget, 2);
                assert_eq!(fwd.sender_authentication, env.sender_authentication);
                assert_eq!(fwd.message_ciphertext, env.message_ciphertext);
            }
            other => panic!("expected Forward, got {other:?}"),
        }
    }

    #[test]
    fn hop_exhausted_drops() {
        let env = sample_env(0, 3, u64::MAX);
        let packed = env.pack();
        assert_eq!(
            decide(&packed, BridgeRole::Relay, 1, false),
            BridgeAction::Drop {
                reason: DropReason::HopExhausted
            }
        );
    }

    #[test]
    fn expired_drops() {
        let env = sample_env(4, 3, 5);
        let packed = env.pack();
        assert_eq!(
            decide(&packed, BridgeRole::Relay, 10, false),
            BridgeAction::Drop {
                reason: DropReason::Expired
            }
        );
    }

    #[test]
    fn exact_expiry_boundary_drops() {
        let env = sample_env(4, 3, 5);
        let packed = env.pack();
        assert_eq!(
            decide(&packed, BridgeRole::Relay, 5, false),
            BridgeAction::Drop {
                reason: DropReason::Expired
            }
        );
    }

    #[test]
    fn duplicate_drops() {
        let env = sample_env(4, 3, u64::MAX);
        let packed = env.pack();
        assert_eq!(
            decide(&packed, BridgeRole::Relay, 1, true),
            BridgeAction::Drop {
                reason: DropReason::Duplicate
            }
        );
    }

    #[test]
    fn endpoint_delivers_local() {
        let env = sample_env(4, 3, u64::MAX);
        let packed = env.pack();
        assert_eq!(
            decide(&packed, BridgeRole::Endpoint, 1, false),
            BridgeAction::DeliverLocal
        );
    }

    #[test]
    fn forward_keeps_signature_valid() {
        let id = Identity::generate();
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 1,
            message_id: [1u8; 16],
            routing_tag: [2u8; 16],
            dest_device_hint: 99,
            created_at: 100,
            expires_at: u64::MAX,
            hop_limit: 8,
            replication_budget: 3,
            anti_replay_nonce: [7u8; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: vec![0x7f, 1, 2, 3],
            sender_authentication: vec![],
        };
        env.sign_with(&id);
        let pubk = id.public_key_bytes();
        assert!(env.verify(&pubk));
        let fwd = prepare_forward(env.clone()).unwrap();
        assert!(fwd.verify(&pubk));
        assert_ne!(fwd.hop_limit, env.hop_limit);
    }

    #[test]
    fn split_replication_binary_spray() {
        assert_eq!(split_replication(1), (0, 1));
        assert_eq!(split_replication(4), (2, 2));
        assert_eq!(split_replication(5), (3, 2));
    }

    #[test]
    fn multi_role_destination_beats_bridge() {
        assert_eq!(
            classify_multi_role(EnvType::Message as u8, true, true),
            MultiRoleDisposition::DeliverToEndpoint
        );
        assert_eq!(
            classify_multi_role(EnvType::Message as u8, false, true),
            MultiRoleDisposition::BridgeForward
        );
        assert_eq!(
            classify_multi_role(EnvType::Ack as u8, false, true),
            MultiRoleDisposition::AckRelay
        );
    }
}
