//! Central MessageRouter for Bridge V1 — opaque envelopes only.
//!
//! Never decrypts. Endpoint delivery is a separate component; this module only
//! classifies ingress → queue / cross-transport forward / drop.
//!
//! Invariants: same message_id; no protocol translation; hop/TTL/dedup/size limits.

use crate::bridge::{prepare_forward, BridgeRole, DropReason, EnvelopeIdentity};
use crate::envelope::{Envelope, EnvType};
use crate::forward_queue::{
    ForwardItem, ForwardQueue, ForwardQueueError, ForwardState, PeerRateDecision,
    MAX_ENVELOPE_BYTES,
};
use crate::transport::{select_path, PathChoice, PathContext, TransportKind};

#[derive(Debug, Clone)]
pub struct InboundEnvelope {
    pub packed: Vec<u8>,
    pub ingress: TransportKind,
    pub previous_hop: String,
    pub now_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouterOutcome {
    /// Local endpoint role should consume (decrypt/ACK outside BridgeSubsystem).
    DeliverToEndpoint { packed: Vec<u8>, identity: EnvelopeIdentity },
    /// Queued for later egress (store-carry-bridge).
    QueuedForForward {
        message_id: [u8; 16],
        egress: TransportKind,
        identity: EnvelopeIdentity,
    },
    /// Ready to send on egress now (packed may have hop/repl decremented).
    ForwardNow {
        packed: Vec<u8>,
        egress: TransportKind,
        identity: EnvelopeIdentity,
    },
    Dropped { reason: DropReason },
    Error(String),
}

pub struct MessageRouter {
    pub bridge_enabled: bool,
    pub store_enabled: bool,
    pub relay_enabled: bool,
    pub endpoint_enabled: bool,
    pub local_has_internet: bool,
    pub local_has_ble: bool,
}

impl Default for MessageRouter {
    fn default() -> Self {
        Self {
            bridge_enabled: true,
            store_enabled: true,
            relay_enabled: false,
            endpoint_enabled: true,
            local_has_internet: true,
            local_has_ble: true,
        }
    }
}

impl MessageRouter {
    /// Choose egress for a cross-transport bridge hop.
    pub fn pick_egress(&self, ingress: TransportKind) -> Option<TransportKind> {
        match ingress {
            TransportKind::Ble | TransportKind::MockBle => {
                if self.local_has_internet {
                    Some(TransportKind::Lan)
                } else if self.store_enabled {
                    Some(TransportKind::Lan) // queue until internet
                } else {
                    None
                }
            }
            TransportKind::Lan | TransportKind::Internet => {
                if self.local_has_ble {
                    Some(TransportKind::MockBle)
                } else if self.store_enabled {
                    Some(TransportKind::MockBle)
                } else {
                    None
                }
            }
        }
    }

    pub fn path_choice(&self, peer_direct: bool, peer_inet: bool, peer_ble: bool) -> PathChoice {
        select_path(&PathContext {
            local_has_internet: self.local_has_internet,
            local_has_ble: self.local_has_ble,
            peer_reachable_direct: peer_direct,
            peer_reachable_internet: peer_inet,
            peer_reachable_ble: peer_ble,
            bridge_enabled: self.bridge_enabled,
            store_enabled: self.store_enabled,
            relay_enabled: self.relay_enabled,
        })
    }

    /// Ingress handler: dedup → TTL/hop → endpoint or bridge queue/forward.
    pub fn handle_inbound(
        &self,
        queue: &ForwardQueue,
        inbound: InboundEnvelope,
        force_bridge: bool,
    ) -> RouterOutcome {
        if inbound.packed.len() > MAX_ENVELOPE_BYTES {
            return RouterOutcome::Dropped {
                reason: DropReason::Malformed,
            };
        }
        let Some(env) = Envelope::unpack(&inbound.packed) else {
            return RouterOutcome::Dropped {
                reason: DropReason::Malformed,
            };
        };
        if EnvType::from_u8(env.env_type).is_none() {
            return RouterOutcome::Dropped {
                reason: DropReason::UnsupportedType,
            };
        }
        if inbound.now_ms > env.expires_at {
            return RouterOutcome::Dropped {
                reason: DropReason::Expired,
            };
        }

        let dup = match queue.seen_check_and_insert(
            &env.message_id,
            inbound.now_ms,
            inbound.ingress,
            &inbound.previous_hop,
        ) {
            Ok(d) => d,
            Err(e) => return RouterOutcome::Error(e.to_string()),
        };
        if dup {
            return RouterOutcome::Dropped {
                reason: DropReason::Duplicate,
            };
        }

        let identity = EnvelopeIdentity::from_envelope(&env);

        // Endpoint may accept when not forcing bridge and endpoint role on.
        // Bridge path always for cross-transport when bridge enabled.
        let want_bridge = force_bridge
            || (self.bridge_enabled && self.pick_egress(inbound.ingress).is_some() && !self.endpoint_only_mode());

        // Multi-role: if bridge enabled and ingress needs cross-transport, bridge wins
        // over local endpoint for Message (ACK reverse also bridges).
        if want_bridge && self.bridge_enabled {
            return self.queue_or_forward(queue, &env, &inbound, identity);
        }

        if self.endpoint_enabled {
            return RouterOutcome::DeliverToEndpoint {
                packed: inbound.packed,
                identity,
            };
        }

        if self.bridge_enabled {
            return self.queue_or_forward(queue, &env, &inbound, identity);
        }

        RouterOutcome::Dropped {
            reason: DropReason::UnsupportedType,
        }
    }

    fn endpoint_only_mode(&self) -> bool {
        self.endpoint_enabled && !self.bridge_enabled
    }

    fn queue_or_forward(
        &self,
        queue: &ForwardQueue,
        env: &Envelope,
        inbound: &InboundEnvelope,
        identity: EnvelopeIdentity,
    ) -> RouterOutcome {
        let Some(egress) = self.pick_egress(inbound.ingress) else {
            return RouterOutcome::Dropped {
                reason: DropReason::UnsupportedType,
            };
        };
        // Abuse protection before mutate/enqueue (spec §24).
        match queue.check_peer_rate(
            &inbound.previous_hop,
            inbound.now_ms,
            inbound.packed.len(),
        ) {
            Ok(PeerRateDecision::Allow) => {}
            Ok(PeerRateDecision::PeerQueueFull) | Ok(PeerRateDecision::RateLimited) => {
                return RouterOutcome::Dropped {
                    reason: DropReason::RateLimited,
                };
            }
            Err(e) => return RouterOutcome::Error(e.to_string()),
        }
        let fwd = match prepare_forward(env.clone()) {
            Ok(e) => e,
            Err(reason) => return RouterOutcome::Dropped { reason },
        };
        // Preserve identity of ciphertext + auth + message_id.
        let after = EnvelopeIdentity::from_envelope(&fwd);
        if !identity.matches_preserved(&after) {
            return RouterOutcome::Error("bridge mutated immutable fields".into());
        }
        let packed = fwd.pack();
        let item = ForwardItem {
            message_id: env.message_id,
            packed_envelope: packed.clone(),
            ingress: inbound.ingress,
            egress,
            state: ForwardState::Queued,
            created_at_ms: inbound.now_ms,
            expires_at_ms: env.expires_at,
            previous_hop: inbound.previous_hop.clone(),
        };
        if let Err(e) = queue.enqueue(&item) {
            return match e {
                ForwardQueueError::QueueFull(_) => RouterOutcome::Dropped {
                    reason: DropReason::Malformed,
                },
                other => RouterOutcome::Error(other.to_string()),
            };
        }

        // If store-only path or egress radio "down", leave queued.
        let egress_ready = match egress {
            TransportKind::Lan | TransportKind::Internet => self.local_has_internet,
            TransportKind::Ble | TransportKind::MockBle => self.local_has_ble,
        };
        if !egress_ready && self.store_enabled {
            return RouterOutcome::QueuedForForward {
                message_id: env.message_id,
                egress,
                identity,
            };
        }

        RouterOutcome::ForwardNow {
            packed,
            egress,
            identity,
        }
    }

    /// After crash: re-load pending and emit ForwardNow / skip expired.
    pub fn recover_pending(
        &self,
        queue: &ForwardQueue,
        now_ms: u64,
    ) -> Result<Vec<(ForwardItem, EnvelopeIdentity)>, String> {
        let items = queue
            .pending_ready(now_ms)
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for item in items {
            let Some(env) = Envelope::unpack(&item.packed_envelope) else {
                let _ = queue.mark_state(&item.message_id, ForwardState::Failed);
                continue;
            };
            if now_ms > env.expires_at {
                let _ = queue.mark_state(&item.message_id, ForwardState::Expired);
                continue;
            }
            let id = EnvelopeIdentity::from_envelope(&env);
            out.push((item, id));
        }
        Ok(out)
    }
}

/// Bridge role helper for decide() compatibility.
pub fn router_role(bridge: bool, endpoint: bool) -> BridgeRole {
    if bridge && !endpoint {
        BridgeRole::Relay
    } else if bridge {
        // Multi-role machine: bridge subsystem still uses Relay semantics for opaque forward.
        BridgeRole::Relay
    } else {
        BridgeRole::Endpoint
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;
    use tempfile::tempdir;

    /// SQLite stores expires as i64 — keep test values <= i64::MAX.
    fn pack_msg(hop: u8, expires: u64, body: &[u8]) -> (Vec<u8>, Identity) {
        let id = Identity::generate();
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [42u8; 16],
            routing_tag: [1u8; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at: expires,
            hop_limit: hop,
            replication_budget: 3,
            anti_replay_nonce: [2u8; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: body.to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&id);
        (env.pack(), id)
    }

    #[test]
    fn ble_to_lan_forward_preserves_id() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
        let router = MessageRouter {
            bridge_enabled: true,
            endpoint_enabled: false,
            local_has_internet: true,
            local_has_ble: true,
            ..Default::default()
        };
        let (packed, _) = pack_msg(5, i64::MAX as u64, b"opaque");
        let before = EnvelopeIdentity::from_envelope(&Envelope::unpack(&packed).unwrap());
        match router.handle_inbound(
            &q,
            InboundEnvelope {
                packed,
                ingress: TransportKind::MockBle,
                previous_hop: "c".into(),
                now_ms: 10,
            },
            true,
        ) {
            RouterOutcome::ForwardNow {
                packed: out,
                egress,
                identity,
            } => {
                assert_eq!(egress, TransportKind::Lan);
                assert!(before.matches_preserved(&identity));
                let env = Envelope::unpack(&out).unwrap();
                assert_eq!(env.message_id, [42u8; 16]);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn store_when_internet_down() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
        let router = MessageRouter {
            bridge_enabled: true,
            store_enabled: true,
            endpoint_enabled: false,
            local_has_internet: false,
            local_has_ble: true,
            ..Default::default()
        };
        let (packed, _) = pack_msg(5, i64::MAX as u64, b"opaque");
        match router.handle_inbound(
            &q,
            InboundEnvelope {
                packed,
                ingress: TransportKind::MockBle,
                previous_hop: "c".into(),
                now_ms: 10,
            },
            true,
        ) {
            RouterOutcome::QueuedForForward { egress, .. } => {
                assert_eq!(egress, TransportKind::Lan);
                assert_eq!(q.count_pending().unwrap(), 1);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn duplicate_dropped() {
        let dir = tempdir().unwrap();
        let q = ForwardQueue::open(&dir.path().join("f.sqlite")).unwrap();
        let router = MessageRouter {
            bridge_enabled: true,
            endpoint_enabled: false,
            ..Default::default()
        };
        let (packed, _) = pack_msg(5, i64::MAX as u64, b"opaque");
        let _ = router.handle_inbound(
            &q,
            InboundEnvelope {
                packed: packed.clone(),
                ingress: TransportKind::Lan,
                previous_hop: "a".into(),
                now_ms: 10,
            },
            true,
        );
        match router.handle_inbound(
            &q,
            InboundEnvelope {
                packed,
                ingress: TransportKind::MockBle,
                previous_hop: "a2".into(),
                now_ms: 11,
            },
            true,
        ) {
            RouterOutcome::Dropped {
                reason: DropReason::Duplicate,
            } => {}
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn recover_after_enqueue() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("f.sqlite");
        let (packed, _) = pack_msg(5, i64::MAX as u64, b"opaque");
        let mid = Envelope::unpack(&packed).unwrap().message_id;
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
                    now_ms: 10,
                },
                true,
            );
        }
        let q = ForwardQueue::open(&path).unwrap();
        let router = MessageRouter::default();
        let recovered = router.recover_pending(&q, 20).unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].0.message_id, mid);
    }
}
