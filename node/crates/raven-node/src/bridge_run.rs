//! Bridge runtime V1 — opaque cross-transport forward inside raven-node.
//!
//! LAN + mock BLE are both TCP length-prefix frames (same RavenEnvelopeV1).
//! BridgeSubsystem never decrypts. Closing `ash` does not stop this process.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use raven_core::ble_adapter::validate_opaque_rvn1;
use raven_core::forward_queue::{ForwardQueue, ForwardState};
use raven_core::message_router::{InboundEnvelope, MessageRouter, RouterOutcome};
use raven_core::node_policy::{load_policy, BridgeStatusSnapshot, NodePolicy};
use raven_core::transport::TransportKind;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

pub fn forward_queue_path(data_dir: &Path) -> PathBuf {
    data_dir.join("forward_queue.sqlite")
}

struct BridgeState {
    policy: NodePolicy,
    queue: ForwardQueue,
    lan_out: Vec<mpsc::Sender<Vec<u8>>>,
    ble_out: Vec<mpsc::Sender<Vec<u8>>>,
}

impl BridgeState {
    fn router(&self) -> MessageRouter {
        MessageRouter {
            bridge_enabled: self.policy.bridge,
            store_enabled: self.policy.store,
            relay_enabled: self.policy.relay,
            endpoint_enabled: false,
            local_has_internet: true,
            local_has_ble: true,
        }
    }

    async fn fanout(&mut self, egress: TransportKind, packed: &[u8]) -> usize {
        // Mock BLE and future GATT share the same opaque RVN1 bytes.
        if matches!(egress, TransportKind::Ble | TransportKind::MockBle)
            && !validate_opaque_rvn1(packed)
        {
            eprintln!("raven-node: BRIDGE drop non-RVN1 on BLE egress");
            return 0;
        }
        let boxes = match egress {
            TransportKind::Lan | TransportKind::Internet => &mut self.lan_out,
            TransportKind::Ble | TransportKind::MockBle => &mut self.ble_out,
        };
        let mut ok = 0usize;
        let mut alive = Vec::new();
        for tx in boxes.drain(..) {
            if tx.send(packed.to_vec()).await.is_ok() {
                ok += 1;
                alive.push(tx);
            }
        }
        *boxes = alive;
        ok
    }

    fn status_snapshot(&self) -> BridgeStatusSnapshot {
        BridgeStatusSnapshot::from_policy(
            &self.policy,
            &["lan", "mock_ble"],
            self.queue.count_pending().unwrap_or(0),
            self.queue.count_all().unwrap_or(0),
        )
    }
}

async fn flush_pending(state: &Arc<Mutex<BridgeState>>) {
    let mut st = state.lock().await;
    if !st.policy.bridge {
        return;
    }
    let pending = match st.router().recover_pending(&st.queue, now_ms()) {
        Ok(p) => p,
        Err(_) => return,
    };
    for (item, identity) in pending {
        let ready = match item.egress {
            TransportKind::Lan | TransportKind::Internet => !st.lan_out.is_empty(),
            TransportKind::Ble | TransportKind::MockBle => !st.ble_out.is_empty(),
        };
        if !ready {
            continue;
        }
        let n = st.fanout(item.egress, &item.packed_envelope).await;
        if n > 0 {
            let _ = st
                .queue
                .mark_object_state(&identity.object_digest, ForwardState::Forwarded);
            eprintln!(
                "raven-node: BRIDGE flush → {} (opaque)",
                item.egress.as_str()
            );
        }
    }
}

async fn on_frame(
    state: &Arc<Mutex<BridgeState>>,
    data_dir: &Path,
    packed: Vec<u8>,
    ingress: TransportKind,
    previous_hop: &str,
) {
    // Lab Test A: always sniff PairResponse OOB before opaque bridge routing.
    if let raven_core::pair_init_lan_oob::PairInitOobClassify::PairResponse(wire) =
        raven_core::pair_init_lan_oob::classify_packed_envelope(&packed)
    {
        let path = data_dir.join("lab_pair_response.rvpr1");
        match std::fs::write(&path, &wire) {
            Ok(()) => eprintln!(
                "raven-node: lab PairResponse → {} ({} bytes)",
                path.display(),
                wire.len()
            ),
            Err(e) => eprintln!("raven-node: lab PairResponse drop write failed: {e}"),
        }
    }

    let mut st = state.lock().await;
    st.policy = load_policy(data_dir);
    if !st.policy.bridge {
        eprintln!("raven-node: bridge policy off — ignore frame");
        return;
    }
    let router = st.router();
    let outcome = router.handle_inbound(
        &st.queue,
        InboundEnvelope {
            packed,
            ingress,
            previous_hop: previous_hop.to_string(),
            now_ms: now_ms(),
        },
        true,
    );
    match outcome {
        RouterOutcome::ForwardNow {
            packed: fwd,
            egress,
            identity,
        } => {
            let n = st.fanout(egress, &fwd).await;
            if n > 0 {
                let _ = st
                    .queue
                    .mark_object_state(&identity.object_digest, ForwardState::Forwarded);
                let mid_hex = raven_core::envelope::Envelope::unpack(&fwd)
                    .map(|e| hex::encode(e.message_id))
                    .unwrap_or_default();
                eprintln!(
                    "raven-node: BRIDGE forward {}→{} (opaque) mid={}",
                    ingress.as_str(),
                    egress.as_str(),
                    mid_hex
                );
            } else {
                let _ = st
                    .queue
                    .mark_object_state(&identity.object_digest, ForwardState::Queued);
                eprintln!(
                    "raven-node: BRIDGE queued waiting {} (opaque)",
                    egress.as_str()
                );
            }
        }
        RouterOutcome::QueuedForForward { egress, .. } => {
            eprintln!(
                "raven-node: BRIDGE store-carry → {} (opaque)",
                egress.as_str()
            );
        }
        RouterOutcome::DeliverToEndpoint { packed, identity } => {
            eprintln!(
                "raven-node: BRIDGE deliver_to_endpoint mid={}",
                hex::encode(&identity.message_id[..4])
            );
            let inbox = data_dir.join("lab_endpoint_inbox");
            let _ = std::fs::create_dir_all(&inbox);
            let name = hex::encode(identity.object_digest);
            let _ = std::fs::write(inbox.join(name), &packed);
        }
        RouterOutcome::Dropped { reason } => {
            eprintln!("raven-node: BRIDGE drop {reason:?}");
        }
        other => eprintln!("raven-node: BRIDGE {other:?}"),
    }
}

async fn accept_loop(
    listener: TcpListener,
    state: Arc<Mutex<BridgeState>>,
    data_dir: PathBuf,
    ingress: TransportKind,
) {
    loop {
        let Ok((stream, addr)) = listener.accept().await else {
            break;
        };
        eprintln!("raven-node: BRIDGE accept {}", ingress.as_str());
        let st = state.clone();
        let dir = data_dir.clone();
        tokio::spawn(async move {
            let (mut reader, mut writer) = stream.into_split();
            let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(64);

            // Do NOT flush on bare accept: probes (nc -z) and half-open connects
            // used to drain the Mac outbox and mark messages Forwarded forever.
            // Wait for pull hello `RVNP`, a stable silent pull (~400ms), or an
            // inbound framed length prefix. Early disconnect → no flush.
            let mut pending_len_prefix: Option<[u8; 4]> = None;
            let is_lan = matches!(ingress, TransportKind::Lan | TransportKind::Internet);
            if is_lan {
                let mut magic = [0u8; 4];
                let classify = tokio::select! {
                    res = reader.read_exact(&mut magic) => match res {
                        Ok(_) if &magic == b"RVNP" => "hello",
                        Ok(_) => "frame",
                        Err(_) => "drop",
                    },
                    _ = tokio::time::sleep(std::time::Duration::from_millis(400)) => "silent",
                };
                match classify {
                    "drop" => {
                        eprintln!("raven-node: BRIDGE drop probe (no flush)");
                        return;
                    }
                    "frame" => {
                        pending_len_prefix = Some(magic);
                    }
                    "hello" | "silent" => {}
                    _ => return,
                }
            }

            {
                let mut s = st.lock().await;
                match ingress {
                    TransportKind::Lan | TransportKind::Internet => s.lan_out.push(out_tx),
                    TransportKind::Ble | TransportKind::MockBle => s.ble_out.push(out_tx),
                }
            }
            if is_lan || matches!(ingress, TransportKind::Ble | TransportKind::MockBle) {
                flush_pending(&st).await;
            }

            let write_task = tokio::spawn(async move {
                while let Some(bytes) = out_rx.recv().await {
                    let len = (bytes.len() as u32).to_be_bytes();
                    if writer.write_all(&len).await.is_err() {
                        break;
                    }
                    if writer.write_all(&bytes).await.is_err() {
                        break;
                    }
                    if writer.flush().await.is_err() {
                        break;
                    }
                }
            });

            loop {
                let len_buf = if let Some(p) = pending_len_prefix.take() {
                    p
                } else {
                    let mut b = [0u8; 4];
                    if reader.read_exact(&mut b).await.is_err() {
                        break;
                    }
                    b
                };
                let len = u32::from_be_bytes(len_buf) as usize;
                if len == 0 || len > 1_048_576 {
                    break;
                }
                let mut buf = vec![0u8; len];
                if reader.read_exact(&mut buf).await.is_err() {
                    break;
                }

                on_frame(&st, &dir, buf, ingress, &addr.to_string()).await;
            }
            write_task.abort();
        });
    }
}

/// Run bridge daemon. `timeout_secs=0` means run until killed (ash exit must NOT stop it
/// when launched as a separate process — ash only edits node_policy.json).
pub async fn run_bridge_daemon(
    data_dir: PathBuf,
    lan_listen: String,
    ble_listen: String,
    write_lan_addr: Option<PathBuf>,
    write_ble_addr: Option<PathBuf>,
    write_status: Option<PathBuf>,
    timeout_secs: u64,
) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).ok();
    let policy = load_policy(&data_dir);
    let queue = ForwardQueue::open(&forward_queue_path(&data_dir)).map_err(|e| e.to_string())?;
    let state = Arc::new(Mutex::new(BridgeState {
        policy,
        queue,
        lan_out: Vec::new(),
        ble_out: Vec::new(),
    }));

    let lan = TcpListener::bind(&lan_listen)
        .await
        .map_err(|e| e.to_string())?;
    let ble = TcpListener::bind(&ble_listen)
        .await
        .map_err(|e| e.to_string())?;
    let lan_addr: SocketAddr = lan.local_addr().map_err(|e| e.to_string())?;
    let ble_addr: SocketAddr = ble.local_addr().map_err(|e| e.to_string())?;
    eprintln!("raven-node: BRIDGE lan listen {lan_addr}");
    eprintln!("raven-node: BRIDGE mock_ble listen {ble_addr}");
    if let Some(p) = write_lan_addr {
        let _ = std::fs::write(p, lan_addr.to_string());
    }
    if let Some(p) = write_ble_addr {
        let _ = std::fs::write(p, ble_addr.to_string());
    }
    {
        let snap = state.lock().await.status_snapshot();
        eprintln!(
            "raven-node: BRIDGE enabled={} store={} pending={}",
            snap.bridge, snap.store, snap.forward_queue_pending
        );
        if let Some(p) = &write_status {
            let _ = std::fs::write(p, serde_json::to_string_pretty(&snap).unwrap_or_default());
        }
    }

    tokio::spawn(accept_loop(
        lan,
        state.clone(),
        data_dir.clone(),
        TransportKind::Lan,
    ));
    tokio::spawn(accept_loop(
        ble,
        state.clone(),
        data_dir.clone(),
        TransportKind::MockBle,
    ));

    let st_pol = state.clone();
    let dir_pol = data_dir.clone();
    let status_path = write_status.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            {
                let mut st = st_pol.lock().await;
                st.policy = load_policy(&dir_pol);
                if let Some(p) = &status_path {
                    let snap = st.status_snapshot();
                    let _ =
                        std::fs::write(p, serde_json::to_string_pretty(&snap).unwrap_or_default());
                }
            }
            flush_pending(&st_pol).await;
        }
    });

    if timeout_secs > 0 {
        tokio::time::sleep(std::time::Duration::from_secs(timeout_secs)).await;
        eprintln!("raven-node: BRIDGE timeout exit");
    } else {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use raven_core::atsam_aead::seal_rvna1_v2;
    use raven_core::envelope::{EnvType, Envelope};
    use raven_core::identity::Identity;
    use tempfile::tempdir;

    #[tokio::test]
    async fn sealed_ack_is_forwarded_opaquely_and_never_marked_delivered() {
        let dir = tempdir().unwrap();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        let (lan_tx, mut lan_rx) = mpsc::channel(1);
        let state = Arc::new(Mutex::new(BridgeState {
            policy: NodePolicy::default(),
            queue,
            lan_out: vec![lan_tx],
            ble_out: Vec::new(),
        }));

        let sender = Identity::generate();
        let message_id = [0xA5; 16];
        let sealed_ack = seal_rvna1_v2(
            &[0x42; 32],
            "recipient-device",
            "origin-device",
            "ack-envelope-1",
            0,
            &[0x77; 101],
            &[0x24; 12],
        )
        .unwrap();
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Ack as u8,
            flags: 0,
            message_id,
            routing_tag: [0x18; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 2,
            anti_replay_nonce: [0x24; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: sealed_ack.clone(),
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&sender);

        on_frame(
            &state,
            dir.path(),
            envelope.pack(),
            TransportKind::MockBle,
            "test-ble-hop",
        )
        .await;

        let forwarded = tokio::time::timeout(std::time::Duration::from_secs(1), lan_rx.recv())
            .await
            .unwrap()
            .unwrap();
        let forwarded = Envelope::unpack(&forwarded).unwrap();
        assert_eq!(forwarded.env_type, EnvType::Ack as u8);
        assert_eq!(forwarded.message_id, message_id);
        assert_eq!(forwarded.message_ciphertext, sealed_ack);

        let stored = state.lock().await.queue.get(&message_id).unwrap().unwrap();
        assert_eq!(stored.state, ForwardState::Forwarded);
    }
}
