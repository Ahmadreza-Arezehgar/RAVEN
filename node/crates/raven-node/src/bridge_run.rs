//! Bridge runtime V1 — opaque cross-transport forward inside raven-node.
//!
//! LAN + mock BLE are both TCP length-prefix frames (same RavenEnvelopeV1).
//! BridgeSubsystem never decrypts. Closing `ash` does not stop this process.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use raven_core::ble_adapter::validate_opaque_rvn1;
use raven_core::envelope::{Envelope, EnvType};
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
    /// message_id → channel to write recipient ACK back to ingress waiter (e.g. A).
    ack_waiters: HashMap<[u8; 16], mpsc::Sender<Vec<u8>>>,
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
                .mark_state(&identity.message_id, ForwardState::Forwarded);
            eprintln!(
                "raven-node: BRIDGE flush mid={} → {}",
                hex::encode(identity.message_id),
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
    // Recipient ACK arriving on reverse transport → wake ingress waiter.
    if let Some(acked) = raven_core::opaque_acked_message_id(&packed) {
        let waiter = {
            let mut st = state.lock().await;
            st.ack_waiters.remove(&acked)
        };
        if let Some(tx) = waiter {
            let _ = tx.send(packed.clone());
            eprintln!(
                "raven-node: BRIDGE recipient ACK mid={} via {}",
                hex::encode(acked),
                ingress.as_str()
            );
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
                    .mark_state(&identity.message_id, ForwardState::Forwarded);
                eprintln!(
                    "raven-node: BRIDGE forward mid={} {}→{} (opaque)",
                    hex::encode(identity.message_id),
                    ingress.as_str(),
                    egress.as_str()
                );
            } else {
                let _ = st
                    .queue
                    .mark_state(&identity.message_id, ForwardState::Queued);
                eprintln!(
                    "raven-node: BRIDGE queued mid={} waiting {}",
                    hex::encode(identity.message_id),
                    egress.as_str()
                );
            }
        }
        RouterOutcome::QueuedForForward {
            message_id, egress, ..
        } => {
            eprintln!(
                "raven-node: BRIDGE store-carry mid={} → {}",
                hex::encode(message_id),
                egress.as_str()
            );
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
        eprintln!(
            "raven-node: BRIDGE accept {} {}",
            ingress.as_str(),
            addr
        );
        let st = state.clone();
        let dir = data_dir.clone();
        tokio::spawn(async move {
            let (mut reader, mut writer) = stream.into_split();
            let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(64);
            // Local reply path for ACKs that must return on THIS socket (A←B).
            let (reply_tx, mut reply_rx) = mpsc::channel::<Vec<u8>>(8);

            {
                let mut s = st.lock().await;
                match ingress {
                    TransportKind::Lan | TransportKind::Internet => s.lan_out.push(out_tx),
                    TransportKind::Ble | TransportKind::MockBle => s.ble_out.push(out_tx),
                }
            }
            flush_pending(&st).await;

            let write_task = tokio::spawn(async move {
                loop {
                    tokio::select! {
                        Some(bytes) = out_rx.recv() => {
                            let len = (bytes.len() as u32).to_be_bytes();
                            if writer.write_all(&len).await.is_err() { break; }
                            if writer.write_all(&bytes).await.is_err() { break; }
                            let _ = writer.flush().await;
                        }
                        Some(bytes) = reply_rx.recv() => {
                            let len = (bytes.len() as u32).to_be_bytes();
                            if writer.write_all(&len).await.is_err() { break; }
                            if writer.write_all(&bytes).await.is_err() { break; }
                            let _ = writer.flush().await;
                        }
                        else => break,
                    }
                }
            });

            loop {
                let mut len_buf = [0u8; 4];
                if reader.read_exact(&mut len_buf).await.is_err() {
                    break;
                }
                let len = u32::from_be_bytes(len_buf) as usize;
                if len == 0 || len > 1_048_576 {
                    break;
                }
                let mut buf = vec![0u8; len];
                if reader.read_exact(&mut buf).await.is_err() {
                    break;
                }

                // LAN Message from A: wait for recipient ACK and reply on this conn.
                if let Some(env) = Envelope::unpack(&buf) {
                    if env.env_type == EnvType::Message as u8
                        && matches!(ingress, TransportKind::Lan | TransportKind::Internet)
                    {
                        let (ack_tx, mut ack_rx) = mpsc::channel::<Vec<u8>>(1);
                        {
                            let mut s = st.lock().await;
                            s.ack_waiters.insert(env.message_id, ack_tx);
                        }
                        on_frame(&st, &dir, buf, ingress, &addr.to_string()).await;
                        if let Ok(Some(ack)) =
                            tokio::time::timeout(std::time::Duration::from_secs(25), ack_rx.recv())
                                .await
                        {
                            let _ = reply_tx.send(ack).await;
                            eprintln!("raven-node: BRIDGE wrote recipient ACK upstream to A");
                        }
                        continue;
                    }
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
        ack_waiters: HashMap::new(),
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
