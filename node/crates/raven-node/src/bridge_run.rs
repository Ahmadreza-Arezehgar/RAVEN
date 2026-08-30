//! Bridge runtime V1 — opaque cross-transport forward inside raven-node.
//!
//! LAN + mock BLE are both TCP length-prefix frames (same RavenEnvelopeV1).
//! BridgeSubsystem never decrypts. Closing `ash` does not stop this process.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rand::RngCore;
use raven_core::ble_adapter::validate_opaque_rvn1;
use raven_core::chat_history::BlockList;
use raven_core::forward_queue::{ForwardQueue, ForwardQueueError, ForwardState};
use raven_core::identity::Identity;
use raven_core::message_router::{InboundEnvelope, MessageRouter, RouterOutcome};
use raven_core::node_policy::{load_policy, BridgeStatusSnapshot, NodePolicy};
use raven_core::transport::TransportKind;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex, Semaphore};

const MAX_BRIDGE_CONNECTIONS: usize = 64;
const BRIDGE_IDLE_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_FRAME_TIMEOUT: Duration = Duration::from_secs(30);
const BRIDGE_WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const BRIDGE_CONNECTION_LIFETIME: Duration = Duration::from_secs(120);
const MAX_BRIDGE_FRAME_BYTES: usize = 1_048_576;
const PULL_OUTBOUND_CAPACITY: usize = 64;
const PULL_HELLO: &[u8; 4] = b"RVNP";
const PULL_CHALLENGE: &[u8; 4] = b"RVNC";
const PULL_RESPONSE: &[u8; 4] = b"RVNS";
const PULL_RECEIPT: &[u8; 4] = b"RVNR";
const PULL_AUTH_DOMAIN: &[u8] = b"raven/bridge-pull/v1";
const PULL_RECEIPT_DOMAIN: &[u8] = b"raven/bridge-receipt/v1";

static LIVE_BRIDGE_PROFILES: OnceLock<StdMutex<HashMap<PathBuf, usize>>> = OnceLock::new();

fn bridge_runtime_key(data_dir: &Path) -> PathBuf {
    std::fs::canonicalize(data_dir).unwrap_or_else(|_| data_dir.to_path_buf())
}

/// Process-local service readiness signal. The combined service runs IPC and
/// bridge listeners in the same process, so policy alone is never presented as
/// a runtime bridge capability before both bridge sockets have bound.
pub(crate) fn bridge_listener_is_up(data_dir: &Path) -> bool {
    let key = bridge_runtime_key(data_dir);
    LIVE_BRIDGE_PROFILES
        .get()
        .and_then(|profiles| {
            let profiles = profiles
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            profiles.get(&key).copied()
        })
        .unwrap_or(0)
        > 0
}

pub(crate) struct BridgeRuntimeGuard {
    profile: PathBuf,
}

impl BridgeRuntimeGuard {
    pub(crate) fn register(data_dir: &Path) -> Self {
        let profile = bridge_runtime_key(data_dir);
        let profiles = LIVE_BRIDGE_PROFILES.get_or_init(|| StdMutex::new(HashMap::new()));
        let mut profiles = profiles
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *profiles.entry(profile.clone()).or_insert(0) += 1;
        Self { profile }
    }
}

impl Drop for BridgeRuntimeGuard {
    fn drop(&mut self) {
        let Some(profiles) = LIVE_BRIDGE_PROFILES.get() else {
            return;
        };
        let mut profiles = profiles
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(count) = profiles.get_mut(&self.profile) {
            *count -= 1;
            if *count == 0 {
                profiles.remove(&self.profile);
            }
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn remove_stale_status(path: Option<&Path>) {
    let Some(path) = path else {
        return;
    };
    if let Err(error) = std::fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            eprintln!(
                "raven-node: remove stale bridge status {} failed: {error}",
                path.display()
            );
        }
    }
}

#[derive(Default)]
struct LivePublicationGuard {
    paths: Vec<PathBuf>,
}

impl LivePublicationGuard {
    fn register(&mut self, path: &Path) {
        if !self.paths.iter().any(|published| published == path) {
            self.paths.push(path.to_path_buf());
        }
    }
}

impl Drop for LivePublicationGuard {
    fn drop(&mut self) {
        for path in &self.paths {
            if let Err(error) = std::fs::remove_file(path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    eprintln!(
                        "raven-node: remove stale live publication {} failed: {error}",
                        path.display()
                    );
                }
            }
        }
    }
}

pub fn forward_queue_path(data_dir: &Path) -> PathBuf {
    data_dir.join("forward_queue.sqlite")
}

struct BridgeState {
    identity: Identity,
    policy: NodePolicy,
    queue: ForwardQueue,
    lan_out: Vec<PullSender>,
    ble_out: Vec<PullSender>,
    /// Exact authenticated pull session selected for the latest successful
    /// channel handoff of each in-flight object. This is deliberately
    /// process-local: after restart the durable InFlight row becomes eligible
    /// for a fresh pull after backoff and is then rebound before any receipt is
    /// accepted.
    attempt_assignments: HashMap<[u8; 32], BridgePullSession>,
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

    fn egress_senders(&mut self, egress: TransportKind, packed: &[u8]) -> Vec<PullSender> {
        // Mock BLE and future GATT share the same opaque RVN1 bytes.
        if matches!(egress, TransportKind::Ble | TransportKind::MockBle)
            && !validate_opaque_rvn1(packed)
        {
            eprintln!("raven-node: BRIDGE drop non-RVN1 on BLE egress");
            return Vec::new();
        }
        let boxes = match egress {
            TransportKind::Lan | TransportKind::Internet => &mut self.lan_out,
            TransportKind::Ble | TransportKind::MockBle => &mut self.ble_out,
        };
        boxes.retain(|sender| !sender.tx.is_closed());
        boxes.clone()
    }

    fn prune_terminal_attempt_assignments(&mut self) {
        let queue = &self.queue;
        self.attempt_assignments
            .retain(|object_digest, _| match queue.get_object(object_digest) {
                Ok(Some(item)) => !matches!(
                    item.state,
                    ForwardState::Forwarded | ForwardState::Expired | ForwardState::Failed
                ),
                Ok(None) => false,
                // A storage read failure is not proof that custody ended.
                Err(_) => true,
            });
    }

    fn acknowledge_custody_receipt(
        &mut self,
        session: &BridgePullSession,
        object_digest: &[u8; 32],
        signature: &[u8; 64],
    ) -> CustodyReceiptDisposition {
        if !session.verify_receipt(object_digest, signature) {
            return CustodyReceiptDisposition::InvalidSignature;
        }
        if self.attempt_assignments.get(object_digest) != Some(session) {
            return CustodyReceiptDisposition::WrongAttempt;
        }
        match self.queue.acknowledge_in_flight(object_digest) {
            Ok(true) => {
                self.attempt_assignments.remove(object_digest);
                CustodyReceiptDisposition::Acknowledged
            }
            Ok(false) | Err(_) => CustodyReceiptDisposition::NotInFlight,
        }
    }

    fn status_snapshot(&self) -> Result<BridgeStatusSnapshot, ForwardQueueError> {
        Ok(BridgeStatusSnapshot::from_policy(
            &self.policy,
            &["lan", "mock_ble"],
            self.queue.count_pending()?,
            self.queue.count_all()?,
        ))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CustodyReceiptDisposition {
    Acknowledged,
    InvalidSignature,
    WrongAttempt,
    NotInFlight,
}

#[derive(Clone)]
struct PullSender {
    tx: mpsc::Sender<Vec<u8>>,
    session: BridgePullSession,
}

struct PullReservation {
    permit: mpsc::OwnedPermit<Vec<u8>>,
    session: BridgePullSession,
}

/// Tokio detaches a spawned task when its JoinHandle is merely dropped. Keep a
/// separate abort handle in the parent connection future so cancellation by the
/// outer lifetime timeout also closes the writer receiver and every registered
/// sender becomes observably closed.
struct AbortTaskOnDrop(tokio::task::AbortHandle);

impl Drop for AbortTaskOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn reserve_one_replica(senders: Vec<PullSender>) -> Option<PullReservation> {
    for sender in senders {
        let PullSender { tx, session } = sender;
        match tx.try_reserve_owned() {
            Ok(permit) => return Some(PullReservation { permit, session }),
            Err(mpsc::error::TrySendError::Full(_)) | Err(mpsc::error::TrySendError::Closed(_)) => {
                continue
            }
        }
    }
    None
}

/// One prepared bridge envelope has consumed exactly one replication token, so
/// this runtime may hand it to at most one next hop. A future spray worker must
/// split the budget into independently persisted children before multi-fanout.
#[cfg(test)]
fn enqueue_one_replica(senders: Vec<PullSender>, packed: &[u8]) -> Option<BridgePullSession> {
    let reservation = reserve_one_replica(senders)?;
    let session = reservation.session;
    reservation.permit.send(packed.to_vec());
    Some(session)
}

async fn attempt_forward(
    state: &Arc<Mutex<BridgeState>>,
    egress: TransportKind,
    packed: &[u8],
    object_digest: &[u8; 32],
) -> bool {
    attempt_forward_at(state, egress, packed, object_digest, now_ms()).await
}

async fn attempt_forward_at(
    state: &Arc<Mutex<BridgeState>>,
    egress: TransportKind,
    packed: &[u8],
    object_digest: &[u8; 32],
    attempt_now_ms: u64,
) -> bool {
    // Claim, non-blocking channel enqueue, and exact session assignment happen
    // under one mutex. A fast peer therefore cannot race a receipt ahead of the
    // assignment, and concurrent flushes cannot bind the same claim twice.
    let mut st = state.lock().await;
    st.prune_terminal_attempt_assignments();
    let senders = st.egress_senders(egress, packed);
    if senders.is_empty() {
        return false;
    }
    // Reserve bounded channel capacity before consuming a durable retry
    // attempt. A full writer queue is local backpressure, not a failed carrier
    // handoff, and must not advance attempt_count/backoff.
    let Some(reservation) = reserve_one_replica(senders) else {
        return false;
    };
    match st
        .queue
        .claim_object_for_attempt(object_digest, attempt_now_ms)
    {
        Ok(true) => {}
        Ok(false) | Err(_) => return false,
    }
    let session = reservation.session;
    reservation.permit.send(packed.to_vec());
    st.attempt_assignments.insert(*object_digest, session);
    // A local channel enqueue is not endpoint delivery. Keep InFlight; it
    // becomes retry-eligible after backoff and only a verifiable protocol
    // receipt may eventually mark it Forwarded.
    true
}

async fn attempt_unstored_forward(
    state: &Arc<Mutex<BridgeState>>,
    egress: TransportKind,
    packed: &[u8],
) -> bool {
    let mut st = state.lock().await;
    let senders = st.egress_senders(egress, packed);
    let Some(reservation) = reserve_one_replica(senders) else {
        return false;
    };
    reservation.permit.send(packed.to_vec());
    true
}

async fn flush_pending(state: &Arc<Mutex<BridgeState>>) {
    let pending = {
        let st = state.lock().await;
        if !st.policy.bridge {
            return;
        }
        match st.router().recover_pending(&st.queue, now_ms()) {
            Ok(p) => p,
            Err(_) => return,
        }
    };
    for (item, identity) in pending {
        if attempt_forward(
            state,
            item.egress,
            &item.packed_envelope,
            &identity.object_digest,
        )
        .await
        {
            eprintln!(
                "raven-node: BRIDGE retry handoff → {} (awaiting receipt)",
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
    // The bridge is an opaque carrier: it must never materialize an embedded
    // PairResponse (or any other endpoint control payload) before endpoint
    // authentication and transcript verification. LAN endpoint dispatch owns
    // PairInit/PairResponse processing; this path only queues/forwards bytes.
    let policy = load_policy(data_dir);
    let (outcome, store_enabled) = {
        let mut st = state.lock().await;
        st.policy = policy;
        if !st.policy.bridge {
            eprintln!("raven-node: bridge policy off — ignore frame");
            return;
        }
        let router = st.router();
        let store_enabled = st.policy.store;
        (
            router.handle_inbound(
                &st.queue,
                InboundEnvelope {
                    packed,
                    ingress,
                    previous_hop: previous_hop.to_string(),
                    now_ms: now_ms(),
                },
                true,
            ),
            store_enabled,
        )
    };
    match outcome {
        RouterOutcome::ForwardNow {
            packed: fwd,
            egress,
            identity,
        } => {
            let handed_off = if store_enabled {
                attempt_forward(state, egress, &fwd, &identity.object_digest).await
            } else {
                attempt_unstored_forward(state, egress, &fwd).await
            };
            if handed_off {
                let mid_hex = raven_core::envelope::Envelope::unpack(&fwd)
                    .map(|e| hex::encode(e.message_id))
                    .unwrap_or_default();
                if store_enabled {
                    eprintln!(
                        "raven-node: BRIDGE forward handoff {}→{} (awaiting receipt) mid={}",
                        ingress.as_str(),
                        egress.as_str(),
                        mid_hex
                    );
                } else {
                    eprintln!(
                        "raven-node: BRIDGE best-effort handoff {}→{} (store off) mid={}",
                        ingress.as_str(),
                        egress.as_str(),
                        mid_hex
                    );
                }
            } else {
                if store_enabled {
                    eprintln!(
                        "raven-node: BRIDGE queued waiting {} (opaque)",
                        egress.as_str()
                    );
                } else {
                    eprintln!(
                        "raven-node: BRIDGE store off and no live {} carrier — dropped",
                        egress.as_str()
                    );
                }
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
    connection_limiter: Arc<Semaphore>,
) -> Result<(), String> {
    loop {
        let (stream, addr) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) if accept_error_is_explicitly_transient(&error) => {
                eprintln!(
                    "raven-node: BRIDGE transient {} accept error: {error}",
                    ingress.as_str()
                );
                continue;
            }
            Err(error) => {
                return Err(format!(
                    "{} listener accept failed: {error}",
                    ingress.as_str()
                ));
            }
        };
        let Ok(permit) = connection_limiter.clone().try_acquire_owned() else {
            eprintln!("raven-node: BRIDGE connection capacity reached");
            drop(stream);
            continue;
        };
        eprintln!("raven-node: BRIDGE accept {}", ingress.as_str());
        let st = state.clone();
        let dir = data_dir.clone();
        tokio::spawn(async move {
            let result = tokio::time::timeout(
                BRIDGE_CONNECTION_LIFETIME,
                handle_connection(stream, st, dir, ingress, addr),
            )
            .await;
            if result.is_err() {
                eprintln!("raven-node: BRIDGE connection lifetime exceeded");
            }
            drop(permit);
        });
    }
}

fn accept_error_is_explicitly_transient(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::Interrupted | std::io::ErrorKind::ConnectionAborted
    )
}

fn accept_task_exit_error(
    transport: &str,
    result: Result<Result<(), String>, tokio::task::JoinError>,
) -> String {
    match result {
        Ok(Err(error)) => format!("{transport} bridge listener stopped: {error}"),
        Ok(Ok(())) => format!("{transport} bridge listener ended unexpectedly"),
        Err(error) => format!("{transport} bridge listener task failed: {error}"),
    }
}

async fn read_exact_with_timeout<R: AsyncRead + Unpin>(
    reader: &mut R,
    buf: &mut [u8],
    deadline: Duration,
) -> Result<(), ()> {
    match tokio::time::timeout(deadline, reader.read_exact(buf)).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(_)) | Err(_) => Err(()),
    }
}

async fn write_bridge_frame<W: AsyncWrite + Unpin>(writer: &mut W, bytes: &[u8]) -> Result<(), ()> {
    if bytes.is_empty() || bytes.len() > MAX_BRIDGE_FRAME_BYTES {
        return Err(());
    }
    let write = async {
        writer
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await?;
        writer.write_all(bytes).await?;
        writer.flush().await
    };
    match tokio::time::timeout(BRIDGE_WRITE_TIMEOUT, write).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(_)) | Err(_) => Err(()),
    }
}

async fn write_all_with_timeout<W: AsyncWrite + Unpin>(
    writer: &mut W,
    bytes: &[u8],
) -> Result<(), String> {
    match tokio::time::timeout(BRIDGE_WRITE_TIMEOUT, writer.write_all(bytes)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("bridge pull write timeout".into()),
    }
}

async fn run_pull_writer<W: AsyncWrite + Unpin>(
    mut writer: W,
    mut out_rx: mpsc::Receiver<Vec<u8>>,
    state: Arc<Mutex<BridgeState>>,
) {
    while let Some(bytes) = out_rx.recv().await {
        if write_bridge_frame(&mut writer, &bytes).await.is_err() {
            break;
        }
        // Receiving freed one bounded slot. Refill from the oldest eligible
        // durable row so queues larger than channel capacity drain on this same
        // authenticated pull connection without requiring a reconnect.
        flush_pending(&state).await;
    }
}

#[derive(serde::Deserialize)]
struct PullContact {
    #[serde(default)]
    pub_hex: String,
    #[serde(default)]
    pinned: bool,
}

fn puller_is_trusted(data_dir: &Path, peer_pub: &[u8; 32]) -> bool {
    let expected = hex::encode(peer_pub);
    let Ok(blocks) = BlockList::load_checked(data_dir) else {
        // Authorization policy is corrupt/unreadable: fail closed.
        return false;
    };
    if blocks.is_blocked(&expected) {
        return false;
    }
    let path = data_dir.join("contacts.json");
    let Ok(raw) = std::fs::read(&path) else {
        return false;
    };
    let Ok(contacts) = serde_json::from_slice::<Vec<PullContact>>(&raw) else {
        return false;
    };
    contacts
        .iter()
        .any(|contact| contact.pinned && contact.pub_hex.trim().eq_ignore_ascii_case(&expected))
}

fn pull_auth_transcript(
    client_pub: &[u8; 32],
    client_nonce: &[u8; 32],
    server_pub: &[u8; 32],
    server_nonce: &[u8; 32],
) -> Vec<u8> {
    let mut transcript = Vec::with_capacity(PULL_AUTH_DOMAIN.len() + 128);
    transcript.extend_from_slice(PULL_AUTH_DOMAIN);
    transcript.extend_from_slice(client_pub);
    transcript.extend_from_slice(client_nonce);
    transcript.extend_from_slice(server_pub);
    transcript.extend_from_slice(server_nonce);
    transcript
}

#[derive(Clone, PartialEq, Eq)]
pub struct BridgePullSession {
    peer_pub: [u8; 32],
    transcript: Vec<u8>,
}

impl BridgePullSession {
    pub fn signed_receipt(&self, identity: &Identity, object_digest: &[u8; 32]) -> Vec<u8> {
        let signing = self.receipt_signing_bytes(object_digest);
        let mut wire = Vec::with_capacity(4 + 32 + 64);
        wire.extend_from_slice(PULL_RECEIPT);
        wire.extend_from_slice(object_digest);
        wire.extend_from_slice(&identity.sign(&signing));
        wire
    }

    fn verify_receipt(&self, object_digest: &[u8; 32], signature: &[u8; 64]) -> bool {
        Identity::verify(
            &self.peer_pub,
            &self.receipt_signing_bytes(object_digest),
            signature,
        )
    }

    fn receipt_signing_bytes(&self, object_digest: &[u8; 32]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(
            PULL_RECEIPT_DOMAIN.len() + self.transcript.len() + object_digest.len(),
        );
        bytes.extend_from_slice(PULL_RECEIPT_DOMAIN);
        bytes.extend_from_slice(&self.transcript);
        bytes.extend_from_slice(object_digest);
        bytes
    }
}

async fn authenticate_pull_server<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    reader: &mut R,
    writer: &mut W,
    state: &Arc<Mutex<BridgeState>>,
    data_dir: &Path,
) -> Result<BridgePullSession, String> {
    let mut hello_body = [0u8; 64];
    read_exact_with_timeout(reader, &mut hello_body, BRIDGE_FRAME_TIMEOUT)
        .await
        .map_err(|_| "truncated bridge pull hello".to_string())?;
    let mut client_pub = [0u8; 32];
    client_pub.copy_from_slice(&hello_body[..32]);
    let mut client_nonce = [0u8; 32];
    client_nonce.copy_from_slice(&hello_body[32..]);
    if !puller_is_trusted(data_dir, &client_pub) {
        return Err("bridge pull peer is not a trusted contact".into());
    }

    let mut server_nonce = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut server_nonce);
    let (server_pub, server_signature) = {
        let st = state.lock().await;
        let server_pub = st.identity.public_key_bytes();
        let transcript =
            pull_auth_transcript(&client_pub, &client_nonce, &server_pub, &server_nonce);
        (server_pub, st.identity.sign(&transcript))
    };
    let mut challenge = Vec::with_capacity(4 + 32 + 32 + 64);
    challenge.extend_from_slice(PULL_CHALLENGE);
    challenge.extend_from_slice(&server_pub);
    challenge.extend_from_slice(&server_nonce);
    challenge.extend_from_slice(&server_signature);
    write_all_with_timeout(writer, &challenge).await?;

    let mut response = [0u8; 68];
    read_exact_with_timeout(reader, &mut response, BRIDGE_FRAME_TIMEOUT)
        .await
        .map_err(|_| "truncated bridge pull response".to_string())?;
    if &response[..4] != PULL_RESPONSE {
        return Err("invalid bridge pull response".into());
    }
    let mut client_signature = [0u8; 64];
    client_signature.copy_from_slice(&response[4..]);
    let transcript = pull_auth_transcript(&client_pub, &client_nonce, &server_pub, &server_nonce);
    if !Identity::verify(&client_pub, &transcript, &client_signature) {
        return Err("bridge pull client signature invalid".into());
    }
    Ok(BridgePullSession {
        peer_pub: client_pub,
        transcript,
    })
}

async fn authenticate_pull_client_io<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    identity: &Identity,
    expected_server_pub: &[u8; 32],
) -> Result<BridgePullSession, String> {
    let client_pub = identity.public_key_bytes();
    let mut client_nonce = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut client_nonce);
    let mut hello = Vec::with_capacity(68);
    hello.extend_from_slice(PULL_HELLO);
    hello.extend_from_slice(&client_pub);
    hello.extend_from_slice(&client_nonce);
    write_all_with_timeout(stream, &hello).await?;

    let mut challenge = [0u8; 132];
    read_exact_with_timeout(stream, &mut challenge, BRIDGE_FRAME_TIMEOUT)
        .await
        .map_err(|_| "truncated bridge pull challenge".to_string())?;
    if &challenge[..4] != PULL_CHALLENGE {
        return Err("invalid bridge pull challenge".into());
    }
    let mut server_pub = [0u8; 32];
    server_pub.copy_from_slice(&challenge[4..36]);
    if &server_pub != expected_server_pub {
        return Err("bridge pull server identity mismatch".into());
    }
    let mut server_nonce = [0u8; 32];
    server_nonce.copy_from_slice(&challenge[36..68]);
    let mut server_signature = [0u8; 64];
    server_signature.copy_from_slice(&challenge[68..]);
    let transcript = pull_auth_transcript(&client_pub, &client_nonce, &server_pub, &server_nonce);
    if !Identity::verify(&server_pub, &transcript, &server_signature) {
        return Err("bridge pull server signature invalid".into());
    }

    let mut response = Vec::with_capacity(68);
    response.extend_from_slice(PULL_RESPONSE);
    response.extend_from_slice(&identity.sign(&transcript));
    write_all_with_timeout(stream, &response).await?;
    Ok(BridgePullSession {
        peer_pub: server_pub,
        transcript,
    })
}

/// Mutually authenticate an explicit bridge pull before the stream is handed
/// to the normal framed endpoint reader.
pub async fn authenticate_bridge_pull_client(
    stream: &mut tokio::net::TcpStream,
    identity: &Identity,
    expected_server_pub: &[u8; 32],
) -> Result<BridgePullSession, String> {
    authenticate_pull_client_io(stream, identity, expected_server_pub).await
}

async fn register_pull_sender(
    state: &Arc<Mutex<BridgeState>>,
    ingress: TransportKind,
    out_tx: &mpsc::Sender<Vec<u8>>,
    session: &BridgePullSession,
) {
    let mut st = state.lock().await;
    let sender = PullSender {
        tx: out_tx.clone(),
        session: session.clone(),
    };
    match ingress {
        TransportKind::Lan | TransportKind::Internet => st.lan_out.push(sender),
        TransportKind::Ble | TransportKind::MockBle => st.ble_out.push(sender),
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    state: Arc<Mutex<BridgeState>>,
    data_dir: PathBuf,
    ingress: TransportKind,
    addr: SocketAddr,
) {
    let (mut reader, mut writer) = stream.into_split();
    let mut pending_prefix: Option<[u8; 4]> = None;
    let mut first = [0u8; 4];
    if read_exact_with_timeout(&mut reader, &mut first, BRIDGE_IDLE_TIMEOUT)
        .await
        .is_err()
    {
        eprintln!("raven-node: BRIDGE drop silent/probe connection (no flush)");
        return;
    }
    let pull_session = if &first == PULL_HELLO {
        match authenticate_pull_server(&mut reader, &mut writer, &state, &data_dir).await {
            Ok(session) => Some(session),
            Err(e) => {
                eprintln!("raven-node: BRIDGE reject pull: {e}");
                return;
            }
        }
    } else {
        pending_prefix = Some(first);
        None
    };

    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>(PULL_OUTBOUND_CAPACITY);
    let writer_state = state.clone();
    let write_task = tokio::spawn(run_pull_writer(writer, out_rx, writer_state));
    let _abort_writer_on_connection_drop = AbortTaskOnDrop(write_task.abort_handle());
    if let Some(session) = pull_session.as_ref() {
        register_pull_sender(&state, ingress, &out_tx, session).await;
        flush_pending(&state).await;
    }

    loop {
        let prefix = if let Some(prefix) = pending_prefix.take() {
            prefix
        } else {
            let mut prefix = [0u8; 4];
            if read_exact_with_timeout(&mut reader, &mut prefix, BRIDGE_IDLE_TIMEOUT)
                .await
                .is_err()
            {
                break;
            }
            prefix
        };
        if &prefix == PULL_HELLO {
            // Authentication has a challenge/response phase that must precede
            // the writer task. Require a fresh connection for each retry.
            break;
        }
        if &prefix == PULL_RECEIPT {
            let Some(session) = pull_session.as_ref() else {
                break;
            };
            let mut receipt = [0u8; 96];
            if read_exact_with_timeout(&mut reader, &mut receipt, BRIDGE_FRAME_TIMEOUT)
                .await
                .is_err()
            {
                break;
            }
            let mut object_digest = [0u8; 32];
            object_digest.copy_from_slice(&receipt[..32]);
            let mut signature = [0u8; 64];
            signature.copy_from_slice(&receipt[32..]);
            let disposition = {
                let mut st = state.lock().await;
                st.acknowledge_custody_receipt(session, &object_digest, &signature)
            };
            match disposition {
                CustodyReceiptDisposition::Acknowledged => {
                    eprintln!(
                        "raven-node: BRIDGE verified custody receipt object={}",
                        hex::encode(&object_digest[..4])
                    );
                }
                CustodyReceiptDisposition::InvalidSignature => {
                    eprintln!("raven-node: BRIDGE reject invalid custody receipt");
                    break;
                }
                CustodyReceiptDisposition::WrongAttempt => {
                    eprintln!("raven-node: BRIDGE reject receipt from unassigned pull session");
                    break;
                }
                CustodyReceiptDisposition::NotInFlight => {
                    eprintln!("raven-node: BRIDGE reject receipt for non-in-flight object");
                    break;
                }
            }
            continue;
        }
        let len = u32::from_be_bytes(prefix) as usize;
        if len == 0 || len > MAX_BRIDGE_FRAME_BYTES {
            break;
        }
        let mut buf = vec![0u8; len];
        if read_exact_with_timeout(&mut reader, &mut buf, BRIDGE_FRAME_TIMEOUT)
            .await
            .is_err()
        {
            break;
        }
        // Source ports are deliberately excluded from durable rate-limit keys.
        on_frame(&state, &data_dir, buf, ingress, &addr.ip().to_string()).await;
    }
    write_task.abort();
    let _ = write_task.await;
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
    // Identity must be established before SQLite/status/address artifacts are
    // created. Otherwise a failed first install is permanently misclassified
    // as an existing profile with a missing identity.
    let (identity, _) = raven_core::load_or_create_identity(&data_dir)
        .map_err(|e| format!("bridge identity preflight failed: {e}"))?;
    let policy = load_policy(&data_dir);
    let queue = ForwardQueue::open(&forward_queue_path(&data_dir)).map_err(|e| e.to_string())?;
    let state = Arc::new(Mutex::new(BridgeState {
        identity,
        policy,
        queue,
        lan_out: Vec::new(),
        ble_out: Vec::new(),
        attempt_assignments: HashMap::new(),
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
    let mut live_publications = LivePublicationGuard::default();
    if let Some(p) = &write_lan_addr {
        raven_core::atomic_write_private(p, lan_addr.to_string().as_bytes())
            .map_err(|e| format!("publish bridge LAN address: {e}"))?;
        live_publications.register(p);
    }
    if let Some(p) = &write_ble_addr {
        raven_core::atomic_write_private(p, ble_addr.to_string().as_bytes())
            .map_err(|e| format!("publish bridge BLE address: {e}"))?;
        live_publications.register(p);
    }
    {
        let snap = state
            .lock()
            .await
            .status_snapshot()
            .map_err(|error| format!("bridge status storage unavailable: {error}"))?;
        eprintln!(
            "raven-node: BRIDGE enabled={} store={} pending={}",
            snap.bridge, snap.store, snap.forward_queue_pending
        );
        if let Some(p) = &write_status {
            let bytes = serde_json::to_vec_pretty(&snap)
                .map_err(|e| format!("serialize bridge status: {e}"))?;
            raven_core::atomic_write_private(p, &bytes)
                .map_err(|e| format!("publish bridge status: {e}"))?;
            live_publications.register(p);
        }
    }

    // Register readiness only after both listeners are bound and their
    // requested publications have completed successfully.
    let _bridge_runtime = BridgeRuntimeGuard::register(&data_dir);

    let connection_limiter = Arc::new(Semaphore::new(MAX_BRIDGE_CONNECTIONS));
    let mut lan_accept_task = tokio::spawn(accept_loop(
        lan,
        state.clone(),
        data_dir.clone(),
        TransportKind::Lan,
        connection_limiter.clone(),
    ));
    let _abort_lan_accept = AbortTaskOnDrop(lan_accept_task.abort_handle());
    let mut ble_accept_task = tokio::spawn(accept_loop(
        ble,
        state.clone(),
        data_dir.clone(),
        TransportKind::MockBle,
        connection_limiter,
    ));
    let _abort_ble_accept = AbortTaskOnDrop(ble_accept_task.abort_handle());

    let st_pol = state.clone();
    let dir_pol = data_dir.clone();
    let status_path = write_status.clone();
    let mut maintenance_task = tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            let policy = load_policy(&dir_pol);
            let storage_healthy = {
                let mut st = st_pol.lock().await;
                st.policy = policy;
                if let Err(error) = st.queue.maintain(now_ms()) {
                    eprintln!("raven-node: bridge queue maintenance storage failure: {error}");
                    false
                } else {
                    true
                }
            };
            if !storage_healthy {
                remove_stale_status(status_path.as_deref());
                continue;
            }
            {
                let mut st = st_pol.lock().await;
                st.prune_terminal_attempt_assignments();
            }
            // A still-live pull is itself an explicit carrier request. Retry
            // eligible InFlight rows after backoff and pick up newly queued
            // rows even when no new connection arrives.
            flush_pending(&st_pol).await;
            let snap = match st_pol.lock().await.status_snapshot() {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    eprintln!("raven-node: bridge status storage failure: {error}");
                    remove_stale_status(status_path.as_deref());
                    continue;
                }
            };
            if let Some(p) = &status_path {
                match serde_json::to_vec_pretty(&snap) {
                    Ok(bytes) => {
                        if let Err(error) = raven_core::atomic_write_private(p, &bytes) {
                            eprintln!("raven-node: bridge status publication failed: {error}");
                        }
                    }
                    Err(error) => {
                        eprintln!("raven-node: bridge status serialization failed: {error}");
                    }
                }
            }
        }
    });
    let _abort_maintenance = AbortTaskOnDrop(maintenance_task.abort_handle());

    let daemon_lifetime = async move {
        if timeout_secs > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(timeout_secs)).await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::pin!(daemon_lifetime);

    let result = tokio::select! {
        accept_result = &mut lan_accept_task => {
            Err(accept_task_exit_error("lan", accept_result))
        }
        accept_result = &mut ble_accept_task => {
            Err(accept_task_exit_error("mock_ble", accept_result))
        }
        maintenance_result = &mut maintenance_task => {
            let error = match maintenance_result {
                Ok(()) => "bridge maintenance task ended unexpectedly".to_string(),
                Err(error) => format!("bridge maintenance task failed: {error}"),
            };
            Err(error)
        }
        _ = &mut daemon_lifetime => {
            eprintln!("raven-node: BRIDGE timeout exit");
            Ok(())
        }
    };

    // Address and status files are live-readiness publications, not historical
    // state. `live_publications` removes all of them on normal return, fatal
    // listener exit, panic unwind, or task abort by the combined service.
    drop(live_publications);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use raven_core::atsam_aead::seal_rvna1_v2;
    use raven_core::envelope::{EnvType, Envelope};
    use raven_core::identity::Identity;
    use tempfile::tempdir;

    #[test]
    fn accept_loop_retries_only_explicit_transient_errors() {
        assert!(accept_error_is_explicitly_transient(&std::io::Error::from(
            std::io::ErrorKind::Interrupted
        )));
        assert!(accept_error_is_explicitly_transient(&std::io::Error::from(
            std::io::ErrorKind::ConnectionAborted
        )));
        for fatal in [
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::AddrNotAvailable,
            std::io::ErrorKind::Other,
        ] {
            assert!(
                !accept_error_is_explicitly_transient(&std::io::Error::from(fatal)),
                "{fatal:?} must terminate the daemon rather than leave stale readiness"
            );
        }

        let error = accept_task_exit_error("lan", Ok(Err("injected fatal accept".to_string())));
        assert!(error.contains("lan bridge listener stopped"));
        assert!(error.contains("injected fatal accept"));
    }

    #[test]
    fn live_publication_guard_removes_all_listener_artifacts() {
        let dir = tempdir().unwrap();
        let lan = dir.path().join("bridge.lan");
        let ble = dir.path().join("bridge.ble");
        let status = dir.path().join("bridge.status.json");
        for path in [&lan, &ble, &status] {
            std::fs::write(path, b"live").unwrap();
        }

        {
            let mut publications = LivePublicationGuard::default();
            publications.register(&lan);
            publications.register(&ble);
            publications.register(&status);
        }

        for path in [&lan, &ble, &status] {
            assert!(
                !path.exists(),
                "listener exit must not leave stale publication {}",
                path.display()
            );
        }
    }

    #[tokio::test]
    async fn store_off_with_no_live_puller_leaves_no_durable_custody() {
        let dir = tempdir().unwrap();
        let policy = NodePolicy {
            store: false,
            ..Default::default()
        };
        raven_core::node_policy::save_policy(dir.path(), &policy).unwrap();
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x31; 32]),
            policy,
            queue: ForwardQueue::open(&forward_queue_path(dir.path())).unwrap(),
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));
        let sender = Identity::from_seed(&[0x32; 32]);
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x33; 16],
            routing_tag: [0x34; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 1,
            anti_replay_nonce: [0x35; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: vec![0x36; 32],
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&sender);

        on_frame(
            &state,
            dir.path(),
            envelope.pack(),
            TransportKind::MockBle,
            "no-live-puller",
        )
        .await;

        let st = state.lock().await;
        assert_eq!(st.queue.count_all().unwrap(), 0);
        assert_eq!(st.queue.count_pending().unwrap(), 0);
        assert!(st.attempt_assignments.is_empty());
    }

    #[tokio::test]
    async fn concurrent_store_off_duplicate_is_handed_to_exactly_one_puller() {
        let dir = tempdir().unwrap();
        let policy = NodePolicy {
            store: false,
            ..Default::default()
        };
        raven_core::node_policy::save_policy(dir.path(), &policy).unwrap();
        let (lan_tx, mut lan_rx) = mpsc::channel(2);
        let pull_identity = Identity::from_seed(&[0x41; 32]);
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x42; 32]),
            policy,
            queue: ForwardQueue::open(&forward_queue_path(dir.path())).unwrap(),
            lan_out: vec![PullSender {
                tx: lan_tx,
                session: BridgePullSession {
                    peer_pub: pull_identity.public_key_bytes(),
                    transcript: b"store-off-dedup".to_vec(),
                },
            }],
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));
        let sender = Identity::from_seed(&[0x43; 32]);
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x44; 16],
            routing_tag: [0x45; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 1,
            anti_replay_nonce: [0x46; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: vec![0x47; 32],
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&sender);
        let packed = envelope.pack();

        tokio::join!(
            on_frame(
                &state,
                dir.path(),
                packed.clone(),
                TransportKind::MockBle,
                "same-hop"
            ),
            on_frame(
                &state,
                dir.path(),
                packed,
                TransportKind::MockBle,
                "same-hop"
            )
        );

        assert!(lan_rx.recv().await.is_some());
        assert!(
            tokio::time::timeout(Duration::from_millis(20), lan_rx.recv())
                .await
                .is_err(),
            "a concurrent replay must not receive a second best-effort handoff"
        );
        let st = state.lock().await;
        assert_eq!(st.queue.count_all().unwrap(), 0);
        assert!(st.attempt_assignments.is_empty());
    }

    #[tokio::test]
    async fn sealed_ack_is_forwarded_opaquely_and_kept_retryable_without_receipt() {
        let dir = tempdir().unwrap();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        let (lan_tx, mut lan_rx) = mpsc::channel(1);
        let pull_identity = Identity::from_seed(&[0x1A; 32]);
        let pull_session = BridgePullSession {
            peer_pub: pull_identity.public_key_bytes(),
            transcript: b"sealed-ack-pull-session".to_vec(),
        };
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x19; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: vec![PullSender {
                tx: lan_tx,
                session: pull_session,
            }],
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
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
        assert_eq!(stored.state, ForwardState::InFlight);
    }

    #[tokio::test]
    async fn opaque_bridge_never_materializes_unverified_pair_response() {
        use raven_core::pair_init::{RESPONSE_MAGIC, RESPONSE_WIRE_LEN};

        let dir = tempdir().unwrap();
        let response_path = dir.path().join("lab_pair_response.rvpr1");
        std::fs::write(&response_path, b"verified-endpoint-owned-sentinel").unwrap();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x31; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));

        // This is deliberately only a magic/length-shaped inner payload. The
        // old bridge sniff overwrote the endpoint's response file before any
        // transcript, signature, trust, or policy verification.
        let mut shaped_response = vec![0u8; RESPONSE_WIRE_LEN];
        shaped_response[..RESPONSE_MAGIC.len()].copy_from_slice(&RESPONSE_MAGIC);
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x32; 16],
            routing_tag: [0x33; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 2,
            anti_replay_nonce: [0x34; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: shaped_response,
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&Identity::from_seed(&[0x35; 32]));

        on_frame(
            &state,
            dir.path(),
            envelope.pack(),
            TransportKind::MockBle,
            "untrusted-hop",
        )
        .await;

        assert_eq!(
            std::fs::read(&response_path).unwrap(),
            b"verified-endpoint-owned-sentinel"
        );
    }

    #[tokio::test]
    async fn one_prepared_envelope_is_never_sprayed_to_multiple_connections() {
        let (first_tx, mut first_rx) = mpsc::channel(1);
        let (second_tx, mut second_rx) = mpsc::channel(1);
        let first_session = BridgePullSession {
            peer_pub: Identity::from_seed(&[0x41; 32]).public_key_bytes(),
            transcript: b"first-pull-session".to_vec(),
        };
        let second_session = BridgePullSession {
            peer_pub: Identity::from_seed(&[0x42; 32]).public_key_bytes(),
            transcript: b"second-pull-session".to_vec(),
        };
        let selected = enqueue_one_replica(
            vec![
                PullSender {
                    tx: first_tx,
                    session: first_session.clone(),
                },
                PullSender {
                    tx: second_tx,
                    session: second_session,
                },
            ],
            b"one-replica",
        );
        assert!(selected.as_ref() == Some(&first_session));
        assert_eq!(first_rx.recv().await.unwrap(), b"one-replica");
        assert!(second_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn live_pull_drains_more_than_channel_capacity_without_reconnect() {
        use raven_core::bridge::authenticated_object_digest;
        use raven_core::forward_queue::ForwardItem;

        const OBJECTS: usize = PULL_OUTBOUND_CAPACITY + 65;
        let dir = tempdir().unwrap();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        let signer = Identity::from_seed(&[0x43; 32]);
        let now = now_ms();
        for i in 0..OBJECTS {
            let mut message_id = [0u8; 16];
            message_id[..8].copy_from_slice(&(i as u64).to_be_bytes());
            let mut nonce = [0u8; 12];
            nonce[..8].copy_from_slice(&(i as u64).to_be_bytes());
            let mut envelope = Envelope {
                env_type: EnvType::Message as u8,
                flags: 0,
                message_id,
                routing_tag: [0x44; 16],
                dest_device_hint: 0,
                created_at: now,
                expires_at: now + 60_000,
                hop_limit: 2,
                replication_budget: 1,
                anti_replay_nonce: nonce,
                ratchet_header_ciphertext: vec![],
                message_ciphertext: (i as u64).to_be_bytes().to_vec(),
                sender_authentication: vec![],
            };
            envelope.sign_with(&signer);
            let object_digest = authenticated_object_digest(&envelope);
            queue
                .enqueue(&ForwardItem {
                    object_digest,
                    message_id,
                    packed_envelope: envelope.pack(),
                    ingress: TransportKind::MockBle,
                    egress: TransportKind::Lan,
                    state: ForwardState::Queued,
                    created_at_ms: now,
                    expires_at_ms: envelope.expires_at,
                    previous_hop: format!("trusted-ingress-{i}"),
                })
                .unwrap();
        }
        let expected = queue
            .pending_ready(now)
            .unwrap()
            .into_iter()
            .map(|item| item.object_digest)
            .collect::<Vec<_>>();
        assert_eq!(expected.len(), OBJECTS);

        let pull_identity = Identity::from_seed(&[0x45; 32]);
        let pull_session = BridgePullSession {
            peer_pub: pull_identity.public_key_bytes(),
            transcript: b"large-live-pull-session".to_vec(),
        };
        let (out_tx, out_rx) = mpsc::channel(PULL_OUTBOUND_CAPACITY);
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x46; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: vec![PullSender {
                tx: out_tx,
                session: pull_session,
            }],
            ble_out: vec![],
            attempt_assignments: HashMap::new(),
        }));

        flush_pending(&state).await;
        assert_eq!(
            state.lock().await.queue.pending_ready(now).unwrap().len(),
            OBJECTS - PULL_OUTBOUND_CAPACITY,
            "initial flush must honor bounded channel capacity"
        );

        let (server, mut client) = tokio::io::duplex(4 * 1024);
        let writer = tokio::spawn(run_pull_writer(server, out_rx, state.clone()));
        let observed = tokio::time::timeout(Duration::from_secs(10), async {
            let mut observed = Vec::with_capacity(OBJECTS);
            for _ in 0..OBJECTS {
                let mut prefix = [0u8; 4];
                client.read_exact(&mut prefix).await.unwrap();
                let len = u32::from_be_bytes(prefix) as usize;
                let mut packed = vec![0u8; len];
                client.read_exact(&mut packed).await.unwrap();
                let envelope = Envelope::unpack(&packed).unwrap();
                observed.push(authenticated_object_digest(&envelope));
            }
            observed
        })
        .await
        .expect("live pull stalled after filling the first bounded channel window");
        assert_eq!(observed, expected);
        writer.abort();
        let _ = writer.await;

        let st = state.lock().await;
        for digest in expected {
            assert_eq!(
                st.queue.get_object(&digest).unwrap().unwrap().state,
                ForwardState::InFlight
            );
        }
    }

    #[test]
    fn custody_receipt_is_signer_and_pull_session_bound() {
        let client = Identity::from_seed(&[0x51; 32]);
        let server_view = BridgePullSession {
            peer_pub: client.public_key_bytes(),
            transcript: b"fresh-session-one".to_vec(),
        };
        let client_view = server_view.clone();
        let digest = [0x52; 32];
        let wire = client_view.signed_receipt(&client, &digest);
        let mut signature = [0u8; 64];
        signature.copy_from_slice(&wire[36..]);
        assert!(server_view.verify_receipt(&digest, &signature));

        let other_session = BridgePullSession {
            peer_pub: client.public_key_bytes(),
            transcript: b"fresh-session-two".to_vec(),
        };
        assert!(!other_session.verify_receipt(&digest, &signature));
        let wrong_signer = BridgePullSession {
            peer_pub: Identity::from_seed(&[0x53; 32]).public_key_bytes(),
            transcript: server_view.transcript.clone(),
        };
        assert!(!wrong_signer.verify_receipt(&digest, &signature));
    }

    #[tokio::test]
    async fn custody_receipt_only_acknowledges_the_exact_selected_attempt_session() {
        use raven_core::bridge::authenticated_object_digest;
        use raven_core::forward_queue::ForwardItem;

        let dir = tempdir().unwrap();
        let first_identity = Identity::from_seed(&[0x54; 32]);
        let first_session = BridgePullSession {
            peer_pub: first_identity.public_key_bytes(),
            transcript: b"trusted-pull-session-a".to_vec(),
        };
        let second_identity = Identity::from_seed(&[0x55; 32]);
        let second_session = BridgePullSession {
            peer_pub: second_identity.public_key_bytes(),
            transcript: b"trusted-pull-session-b".to_vec(),
        };
        let (first_tx, mut first_rx) = mpsc::channel(1);
        let (second_tx, mut second_rx) = mpsc::channel(1);

        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x56; 16],
            routing_tag: [0x57; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 1,
            anti_replay_nonce: [0x58; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: vec![0x59; 32],
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&Identity::from_seed(&[0x5A; 32]));
        let object_digest = authenticated_object_digest(&envelope);
        let packed = envelope.pack();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        queue
            .enqueue(&ForwardItem {
                object_digest,
                message_id: envelope.message_id,
                packed_envelope: packed.clone(),
                ingress: TransportKind::MockBle,
                egress: TransportKind::Lan,
                state: ForwardState::Queued,
                created_at_ms: now,
                expires_at_ms: envelope.expires_at,
                previous_hop: "trusted-ingress".into(),
            })
            .unwrap();
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x5B; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: vec![
                PullSender {
                    tx: first_tx,
                    session: first_session.clone(),
                },
                PullSender {
                    tx: second_tx,
                    session: second_session.clone(),
                },
            ],
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));

        assert!(attempt_forward_at(&state, TransportKind::Lan, &packed, &object_digest, now).await);
        assert_eq!(first_rx.recv().await.unwrap(), packed);
        assert!(second_rx.try_recv().is_err());
        {
            let st = state.lock().await;
            assert!(st.attempt_assignments.get(&object_digest) == Some(&first_session));
            assert_eq!(
                st.queue.get_object(&object_digest).unwrap().unwrap().state,
                ForwardState::InFlight
            );
        }

        // Session B is independently trusted and its receipt is cryptographically
        // valid for B's transcript, but it was not selected for this handoff.
        let wrong_wire = second_session.signed_receipt(&second_identity, &object_digest);
        let mut wrong_signature = [0u8; 64];
        wrong_signature.copy_from_slice(&wrong_wire[36..]);
        {
            let mut st = state.lock().await;
            assert_eq!(
                st.acknowledge_custody_receipt(&second_session, &object_digest, &wrong_signature),
                CustodyReceiptDisposition::WrongAttempt
            );
            assert!(st.attempt_assignments.get(&object_digest) == Some(&first_session));
            assert_eq!(
                st.queue.get_object(&object_digest).unwrap().unwrap().state,
                ForwardState::InFlight
            );
        }

        // Once retry backoff elapses, selecting B is a legitimate new attempt
        // and atomically overwrites A's binding.
        {
            let mut st = state.lock().await;
            let retry_sender = st.lan_out[1].clone();
            st.lan_out = vec![retry_sender];
        }
        assert!(
            attempt_forward_at(
                &state,
                TransportKind::Lan,
                &packed,
                &object_digest,
                now + 6_000
            )
            .await
        );
        assert_eq!(second_rx.recv().await.unwrap(), packed);
        assert!(
            state.lock().await.attempt_assignments.get(&object_digest) == Some(&second_session)
        );

        let stale_wire = first_session.signed_receipt(&first_identity, &object_digest);
        let mut stale_signature = [0u8; 64];
        stale_signature.copy_from_slice(&stale_wire[36..]);
        {
            let mut st = state.lock().await;
            assert_eq!(
                st.acknowledge_custody_receipt(&first_session, &object_digest, &stale_signature),
                CustodyReceiptDisposition::WrongAttempt
            );
            assert!(st.attempt_assignments.get(&object_digest) == Some(&second_session));
        }

        let correct_wire = second_session.signed_receipt(&second_identity, &object_digest);
        let mut correct_signature = [0u8; 64];
        correct_signature.copy_from_slice(&correct_wire[36..]);
        let mut st = state.lock().await;
        assert_eq!(
            st.acknowledge_custody_receipt(&second_session, &object_digest, &correct_signature),
            CustodyReceiptDisposition::Acknowledged
        );
        assert!(!st.attempt_assignments.contains_key(&object_digest));
        assert_eq!(
            st.queue.get_object(&object_digest).unwrap().unwrap().state,
            ForwardState::Forwarded
        );
    }

    #[test]
    fn terminal_queue_cleanup_removes_stale_attempt_assignment() {
        use raven_core::bridge::authenticated_object_digest;
        use raven_core::forward_queue::ForwardItem;

        let dir = tempdir().unwrap();
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x5C; 16],
            routing_tag: [0x5D; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 1,
            hop_limit: 2,
            replication_budget: 1,
            anti_replay_nonce: [0x5E; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: vec![0x5F; 8],
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&Identity::from_seed(&[0x60; 32]));
        let object_digest = authenticated_object_digest(&envelope);
        let packed = envelope.pack();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        queue
            .enqueue(&ForwardItem {
                object_digest,
                message_id: envelope.message_id,
                packed_envelope: packed,
                ingress: TransportKind::MockBle,
                egress: TransportKind::Lan,
                state: ForwardState::Queued,
                created_at_ms: now,
                expires_at_ms: envelope.expires_at,
                previous_hop: "trusted-ingress".into(),
            })
            .unwrap();
        assert!(queue.claim_object_for_attempt(&object_digest, now).unwrap());
        queue.expire_stale(now + 2).unwrap();
        let session = BridgePullSession {
            peer_pub: Identity::from_seed(&[0x61; 32]).public_key_bytes(),
            transcript: b"terminal-cleanup-session".to_vec(),
        };
        let mut state = BridgeState {
            identity: Identity::from_seed(&[0x62; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::from([(object_digest, session)]),
        };

        state.prune_terminal_attempt_assignments();
        assert!(!state.attempt_assignments.contains_key(&object_digest));
    }

    #[tokio::test]
    async fn mutually_authenticated_pull_accepts_only_trusted_client_and_pinned_server() {
        let dir = tempdir().unwrap();
        let server_identity = Identity::from_seed(&[0x61; 32]);
        let server_pub = server_identity.public_key_bytes();
        let client_identity = Identity::from_seed(&[0x62; 32]);
        std::fs::write(
            dir.path().join("contacts.json"),
            serde_json::to_vec(&serde_json::json!([{
                "pub_hex": hex::encode(client_identity.public_key_bytes()),
                "pinned": true
            }]))
            .unwrap(),
        )
        .unwrap();
        let state = Arc::new(Mutex::new(BridgeState {
            identity: server_identity,
            policy: NodePolicy::default(),
            queue: ForwardQueue::open(&forward_queue_path(dir.path())).unwrap(),
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));
        let (mut client, server) = tokio::io::duplex(1024);
        let (mut server_reader, mut server_writer) = tokio::io::split(server);
        let server_state = state.clone();
        let server_dir = dir.path().to_path_buf();
        let server_task = tokio::spawn(async move {
            let mut marker = [0u8; 4];
            read_exact_with_timeout(&mut server_reader, &mut marker, BRIDGE_FRAME_TIMEOUT)
                .await
                .map_err(|_| "missing pull marker".to_string())?;
            if &marker != PULL_HELLO {
                return Err("wrong pull marker".into());
            }
            authenticate_pull_server(
                &mut server_reader,
                &mut server_writer,
                &server_state,
                &server_dir,
            )
            .await
        });
        authenticate_pull_client_io(&mut client, &client_identity, &server_pub)
            .await
            .unwrap();
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn cancelling_connection_aborts_writer_and_prunes_closed_pull_sender() {
        let dir = tempdir().unwrap();
        let server_identity = Identity::from_seed(&[0x65; 32]);
        let server_pub = server_identity.public_key_bytes();
        let client_identity = Identity::from_seed(&[0x66; 32]);
        std::fs::write(
            dir.path().join("contacts.json"),
            serde_json::to_vec(&serde_json::json!([{
                "pub_hex": hex::encode(client_identity.public_key_bytes()),
                "pinned": true
            }]))
            .unwrap(),
        )
        .unwrap();
        let state = Arc::new(Mutex::new(BridgeState {
            identity: server_identity,
            policy: NodePolicy::default(),
            queue: ForwardQueue::open(&forward_queue_path(dir.path())).unwrap(),
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (client, accepted) =
            tokio::join!(tokio::net::TcpStream::connect(address), listener.accept());
        let mut client = client.unwrap();
        let (server, peer_addr) = accepted.unwrap();
        let handler_state = state.clone();
        let handler_dir = dir.path().to_path_buf();
        let handler = tokio::spawn(async move {
            handle_connection(
                server,
                handler_state,
                handler_dir,
                TransportKind::Lan,
                peer_addr,
            )
            .await;
        });
        authenticate_pull_client_io(&mut client, &client_identity, &server_pub)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if state.lock().await.lan_out.len() == 1 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("authenticated pull sender was not registered");
        assert!(!state.lock().await.lan_out[0].tx.is_closed());

        // The production 120-second timeout cancels handle_connection in the
        // same way: dropping the parent future must abort, not detach, writer.
        handler.abort();
        assert!(handler.await.unwrap_err().is_cancelled());
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if state.lock().await.lan_out[0].tx.is_closed() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("cancelled connection left its pull writer detached");

        let mut st = state.lock().await;
        assert!(st.lan_out[0].tx.is_closed());
        assert!(st.egress_senders(TransportKind::Lan, b"opaque").is_empty());
        assert!(st.lan_out.is_empty());
    }

    #[test]
    fn pull_authorization_requires_an_explicitly_pinned_contact() {
        let dir = tempdir().unwrap();
        let trusted = Identity::from_seed(&[0x63; 32]);
        let other = Identity::from_seed(&[0x64; 32]);
        let contacts = dir.path().join("contacts.json");

        std::fs::write(
            &contacts,
            serde_json::to_vec(&serde_json::json!([{
                "pub_hex": hex::encode(trusted.public_key_bytes()),
                "pinned": false
            }]))
            .unwrap(),
        )
        .unwrap();
        assert!(!puller_is_trusted(dir.path(), &trusted.public_key_bytes()));

        std::fs::write(
            &contacts,
            serde_json::to_vec(&serde_json::json!([{
                "pub_hex": hex::encode(trusted.public_key_bytes()),
                "pinned": true
            }]))
            .unwrap(),
        )
        .unwrap();
        assert!(puller_is_trusted(dir.path(), &trusted.public_key_bytes()));
        assert!(!puller_is_trusted(dir.path(), &other.public_key_bytes()));

        let trusted_hex = hex::encode(trusted.public_key_bytes());
        let mut blocks = BlockList::default();
        blocks.block(&trusted_hex);
        blocks.save(dir.path()).unwrap();
        assert!(
            !puller_is_trusted(dir.path(), &trusted.public_key_bytes()),
            "a pinned contact must lose bridge-pull authorization immediately when blocked"
        );

        std::fs::write(dir.path().join("blocked_pubs.json"), b"{corrupt-json").unwrap();
        assert!(
            !puller_is_trusted(dir.path(), &other.public_key_bytes()),
            "corrupt block policy must fail closed"
        );
    }

    #[tokio::test]
    async fn bare_rvnp_cannot_register_or_drain_queued_custody() {
        let dir = tempdir().unwrap();
        let queue = ForwardQueue::open(&forward_queue_path(dir.path())).unwrap();
        let sender = Identity::from_seed(&[0x71; 32]);
        let now = now_ms();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x72; 16],
            routing_tag: [0x73; 16],
            dest_device_hint: 0,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 3,
            replication_budget: 2,
            anti_replay_nonce: [0x74; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: vec![0x75; 32],
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&sender);
        let state = Arc::new(Mutex::new(BridgeState {
            identity: Identity::from_seed(&[0x76; 32]),
            policy: NodePolicy::default(),
            queue,
            lan_out: Vec::new(),
            ble_out: Vec::new(),
            attempt_assignments: HashMap::new(),
        }));
        on_frame(
            &state,
            dir.path(),
            envelope.pack(),
            TransportKind::MockBle,
            "192.0.2.1",
        )
        .await;
        assert_eq!(state.lock().await.queue.count_pending().unwrap(), 1);

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (client, accepted) =
            tokio::join!(tokio::net::TcpStream::connect(address), listener.accept());
        let mut client = client.unwrap();
        let (server, peer_addr) = accepted.unwrap();
        let server_state = state.clone();
        let server_dir = dir.path().to_path_buf();
        let handler = tokio::spawn(async move {
            handle_connection(
                server,
                server_state,
                server_dir,
                TransportKind::Lan,
                peer_addr,
            )
            .await
        });
        client.write_all(PULL_HELLO).await.unwrap();
        client.shutdown().await.unwrap();
        handler.await.unwrap();

        let st = state.lock().await;
        assert!(st.lan_out.is_empty());
        let stored = st.queue.get(&[0x72; 16]).unwrap().unwrap();
        assert_eq!(stored.state, ForwardState::Queued);
    }

    #[tokio::test]
    async fn identity_preflight_failure_never_creates_forward_queue() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("unexpected-existing-state"), b"poison").unwrap();
        let result = run_bridge_daemon(
            dir.path().to_path_buf(),
            "127.0.0.1:0".into(),
            "127.0.0.1:0".into(),
            None,
            None,
            None,
            1,
        )
        .await;
        assert!(result.is_err());
        assert!(!forward_queue_path(dir.path()).exists());
    }
}
