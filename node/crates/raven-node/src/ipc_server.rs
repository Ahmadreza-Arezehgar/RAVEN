//! Same-user local IPC server.
//!
//! Unix uses a mode-0600 UDS plus peer UID credentials. Windows uses a
//! per-profile named pipe with a protected current-user DACL, rejects remote
//! clients, and verifies both the client process SID and Windows session after
//! connect. Requests still refuse secret field names (`raven_core::ipc`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use raven_core::bridge::authenticated_object_digest;
use raven_core::envelope::Envelope;
use raven_core::forward_queue::{ForwardItem, ForwardQueue, ForwardState};
#[cfg(unix)]
use raven_core::ipc::default_socket_path;
use raven_core::ipc::{decode_request, encode_response, IpcRequest, IpcResponse, IPC_VERSION};
#[cfg(windows)]
use raven_core::ipc::{
    default_named_pipe_name,
    windows_pipe::{verify_peer_user_and_session, PipePeer, SameUserSecurityAttributes},
};
use tokio::time::Duration;

use crate::lan_direct;

const IPC_IO_TIMEOUT: Duration = Duration::from_secs(10);
const LAN_DIAL_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_IPC_CONNECTION_HANDLERS: usize = 32;
use raven_core::node_policy::{load_policy, save_policy};
use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use raven_core::transport::TransportKind;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
#[cfg(windows)]
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};

fn try_acquire_ipc_handler(limiter: &Arc<Semaphore>) -> Option<OwnedSemaphorePermit> {
    limiter.clone().try_acquire_owned().ok()
}

#[cfg(unix)]
pub fn socket_path(data_dir: &Path) -> PathBuf {
    default_socket_path(data_dir)
}

/// Return true iff the connected peer's effective UID matches ours.
/// Denies cross-user local clients even if they somehow open the socket.
#[cfg(unix)]
fn peer_uid_matches_self(stream: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let fd = stream.as_raw_fd();
    let self_uid = unsafe { libc::geteuid() };

    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd",
        target_os = "dragonfly"
    ))]
    {
        let mut euid: libc::uid_t = 0;
        let mut egid: libc::gid_t = 0;
        let rc = unsafe { libc::getpeereid(fd, &mut euid, &mut egid) };
        if rc != 0 {
            return false;
        }
        euid == self_uid
    }

    #[cfg(target_os = "linux")]
    {
        let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut cred as *mut _ as *mut libc::c_void,
                &mut len,
            )
        };
        if rc != 0 {
            return false;
        }
        cred.uid == self_uid
    }

    #[cfg(not(any(
        target_os = "linux",
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd",
        target_os = "dragonfly"
    )))]
    {
        let _ = (fd, self_uid);
        // Unknown Unix: fall back to socket mode 0600 only.
        true
    }
}

async fn read_frame<S>(stream: &mut S) -> Result<Vec<u8>, String>
where
    S: AsyncRead + Unpin,
{
    let read = async {
        let mut len_buf = [0u8; 4];
        stream
            .read_exact(&mut len_buf)
            .await
            .map_err(|e| e.to_string())?;
        let n = u32::from_be_bytes(len_buf) as usize;
        if n == 0 || n > raven_core::MAX_IPC_FRAME {
            return Err("IPC_FRAME".into());
        }
        let mut buf = vec![0u8; 4 + n];
        buf[0..4].copy_from_slice(&len_buf);
        stream
            .read_exact(&mut buf[4..])
            .await
            .map_err(|e| e.to_string())?;
        Ok(buf)
    };
    tokio::time::timeout(IPC_IO_TIMEOUT, read)
        .await
        .map_err(|_| "ipc read timeout".to_string())?
}

fn unix_time_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn build_status_response(
    v: u16,
    policy: &raven_core::node_policy::NodePolicy,
    has_forward_queue: bool,
    forward_pending: Result<u64, String>,
    lan_listener_up: bool,
    bridge_listener_up: bool,
) -> IpcResponse {
    let pending = match forward_pending {
        Ok(pending) => pending,
        Err(message) => {
            eprintln!("raven-node ipc: status storage failure: {message}");
            return IpcResponse::Error {
                v,
                code: "STORAGE".into(),
                message,
            };
        }
    };
    let mut capabilities = vec!["ipc".into()];
    if lan_listener_up {
        capabilities.push("lan_direct".into());
    }
    // Policy is intent, not readiness. Advertise bridge only while this
    // service process owns live bound bridge listeners for the same profile.
    if policy.bridge && bridge_listener_up {
        capabilities.push("bridge".into());
    }
    if has_forward_queue && policy.store {
        capabilities.push("store".into());
    }
    if has_forward_queue && policy.relay {
        capabilities.push("relay".into());
    }
    IpcResponse::Status {
        v,
        bridge: policy.bridge,
        store: policy.store,
        relay: policy.relay,
        forward_pending: pending,
        capabilities,
    }
}

fn handle_req(req: IpcRequest, data_dir: &Path, forward: &Option<ForwardQueue>) -> IpcResponse {
    handle_req_at(req, data_dir, forward, unix_time_ms())
}

fn handle_req_at(
    req: IpcRequest,
    data_dir: &Path,
    forward: &Option<ForwardQueue>,
    request_now_ms: u64,
) -> IpcResponse {
    match req {
        IpcRequest::Ping { v } => IpcResponse::Pong { v },
        IpcRequest::Status { v } => {
            let policy = load_policy(data_dir);
            let (has_forward_queue, pending) = match forward {
                Some(q) => (
                    true,
                    q.count_pending()
                        .map(|count| count as u64)
                        .map_err(|error| error.to_string()),
                ),
                None => (false, Ok(0)),
            };
            build_status_response(
                v,
                &policy,
                has_forward_queue,
                pending,
                crate::lan_direct::listener_is_up(),
                crate::bridge_run::bridge_listener_is_up(data_dir),
            )
        }
        IpcRequest::SetPolicy {
            v,
            bridge,
            store,
            relay,
        } => {
            let mut p = load_policy(data_dir);
            if let Some(b) = bridge {
                p.bridge = b;
                p.auto_policy = false;
            }
            if let Some(s) = store {
                p.store = s;
                p.auto_policy = false;
            }
            if let Some(r) = relay {
                p.relay = r;
                p.auto_policy = false;
            }
            match save_policy(data_dir, &p) {
                Ok(()) => IpcResponse::Accepted { v },
                Err(e) => IpcResponse::Error {
                    v,
                    code: "INTERNAL".into(),
                    message: e.to_string(),
                },
            }
        }
        IpcRequest::EnqueueSealed {
            v,
            envelope_b64,
            peer_hint,
        } => {
            if envelope_b64.len() > 512 * 1024 {
                return IpcResponse::Error {
                    v,
                    code: "IPC_FRAME".into(),
                    message: "envelope too large".into(),
                };
            }
            let packed = match base64_decode(&envelope_b64) {
                Ok(b) => b,
                Err(e) => {
                    return IpcResponse::Error {
                        v,
                        code: "IPC_BAD_B64".into(),
                        message: e,
                    };
                }
            };
            if packed.len() > raven_core::forward_queue::MAX_ENVELOPE_BYTES {
                return IpcResponse::Error {
                    v,
                    code: "IPC_FRAME".into(),
                    message: "envelope too large".into(),
                };
            }
            let Some(env) = Envelope::unpack(&packed) else {
                return IpcResponse::Error {
                    v,
                    code: "IPC_BAD_ENVELOPE".into(),
                    message: "not a RavenEnvelopeV1".into(),
                };
            };
            if env.expires_at <= request_now_ms {
                return IpcResponse::Error {
                    v,
                    code: "IPC_EXPIRED".into(),
                    message: "sealed envelope is expired".into(),
                };
            }
            let now = request_now_ms;
            let peer = peer_hint.unwrap_or_else(|| "ipc".into());
            // Forward custody is authoritative when the always-on bridge is
            // available. The user outbox is then a best-effort mirror: never
            // report failure after durable custody was already accepted and
            // may have been handed to a live carrier.
            let forward_accepted = if let Some(q) = forward {
                let item = ForwardItem {
                    object_digest: authenticated_object_digest(&env),
                    message_id: env.message_id,
                    packed_envelope: packed.clone(),
                    ingress: TransportKind::Internet,
                    egress: TransportKind::Internet,
                    state: ForwardState::Queued,
                    created_at_ms: now,
                    // Sender-authenticated expiry is a hard upper bound. The
                    // local queue must never grant the object a fresh lease.
                    expires_at_ms: env.expires_at,
                    previous_hop: peer.clone(),
                };
                if let Err(e) = q.enqueue(&item) {
                    return IpcResponse::Error {
                        v,
                        code: "QUEUE_FULL".into(),
                        message: e.to_string(),
                    };
                }
                true
            } else {
                false
            };
            let outbox_path = data_dir.join("queue.sqlite");
            let mirror_result = match OutgoingQueue::open(&outbox_path) {
                Ok(oq) => {
                    let item = QueueItem {
                        message_id: env.message_id,
                        packed_envelope: packed,
                        peer_addr: peer,
                        state: DeliveryState::Queued,
                        created_at_ms: now,
                    };
                    oq.enqueue(&item).map_err(|error| error.to_string())
                }
                Err(error) => Err(error.to_string()),
            };
            match mirror_result {
                Ok(()) => IpcResponse::Accepted { v },
                Err(error) if forward_accepted => {
                    eprintln!(
                        "raven-node ipc: optional outbox mirror failed after durable forward custody: {error}"
                    );
                    IpcResponse::Accepted { v }
                }
                Err(error) => IpcResponse::Error {
                    v,
                    code: "OUTBOX".into(),
                    message: error,
                },
            }
        }
        IpcRequest::LanDial { v, .. } => IpcResponse::Error {
            v,
            code: "INTERNAL".into(),
            message: "LanDial must be handled asynchronously".into(),
        },
    }
}

fn b64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

async fn handle_lan_dial(data_dir: &Path, req: IpcRequest) -> IpcResponse {
    let IpcRequest::LanDial {
        v,
        lan_dial,
        expected_pub_hex,
        frames_b64,
    } = req
    else {
        return IpcResponse::Error {
            v: IPC_VERSION,
            code: "INTERNAL".into(),
            message: "not LanDial".into(),
        };
    };
    let mut frames = Vec::new();
    for item in frames_b64 {
        match base64_decode(&item) {
            Ok(b) => frames.push(b),
            Err(e) => {
                return IpcResponse::Error {
                    v,
                    code: "IPC_BAD_B64".into(),
                    message: e,
                };
            }
        }
    }
    let work = lan_direct::dial(data_dir, &lan_dial, &expected_pub_hex, &frames);
    match tokio::time::timeout(LAN_DIAL_TIMEOUT, work).await {
        Ok(Ok(replies)) => IpcResponse::LanDialResult {
            v,
            frames_b64: replies.iter().map(|f| b64_encode(f)).collect(),
        },
        Ok(Err(e)) => IpcResponse::Error {
            v,
            code: "LAN_DIAL".into(),
            message: e,
        },
        Err(_) => IpcResponse::Error {
            v,
            code: "LAN_DIAL_TIMEOUT".into(),
            message: "lan dial exceeded 45s".into(),
        },
    }
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s.trim()))
        .map_err(|e| e.to_string())
}

async fn serve_one<S>(
    mut stream: S,
    data_dir: Arc<PathBuf>,
    forward: Arc<Mutex<Option<ForwardQueue>>>,
) where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let frame = match read_frame(&mut stream).await {
        Ok(f) => f,
        Err(_) => return,
    };
    let resp = match decode_request(&frame) {
        Ok(req @ IpcRequest::LanDial { .. }) => handle_lan_dial(&data_dir, req).await,
        Ok(req) => {
            let fwd = forward.lock().await;
            handle_req(req, &data_dir, &fwd)
        }
        Err(e) => {
            let code = if e.contains("forbidden") {
                "IPC_FORBIDDEN_FIELD"
            } else if e.contains("version") {
                "IPC_VERSION"
            } else {
                "IPC_FRAME"
            };
            IpcResponse::Error {
                v: IPC_VERSION,
                code: code.into(),
                message: e,
            }
        }
    };
    if let Ok(out) = encode_response(&resp) {
        let _ = tokio::time::timeout(IPC_IO_TIMEOUT, async {
            stream.write_all(&out).await.ok()?;
            stream.flush().await.ok()?;
            Some(())
        })
        .await;
    }
}

/// Bind UDS with mode 0600 and serve until the process exits.
#[cfg(unix)]
fn bind_secure_unix_listener(sock: &Path) -> Result<UnixListener, String> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};

    match std::fs::symlink_metadata(sock) {
        Ok(_) => std::fs::remove_file(sock)
            .map_err(|error| format!("remove stale IPC socket {}: {error}", sock.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "inspect stale IPC socket {}: {error}",
                sock.display()
            ));
        }
    }

    let listener =
        UnixListener::bind(sock).map_err(|error| format!("bind {}: {error}", sock.display()))?;
    let secure = (|| -> Result<(), String> {
        std::fs::set_permissions(sock, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("chmod IPC socket {}: {error}", sock.display()))?;
        let metadata = std::fs::symlink_metadata(sock)
            .map_err(|error| format!("inspect IPC socket {}: {error}", sock.display()))?;
        if !metadata.file_type().is_socket() {
            return Err(format!("IPC path {} is not a Unix socket", sock.display()));
        }
        let mode = metadata.mode() & 0o7777;
        if mode != 0o600 {
            return Err(format!(
                "IPC socket {} has insecure mode {mode:04o}",
                sock.display()
            ));
        }
        let expected_uid = unsafe { libc::geteuid() };
        if metadata.uid() != expected_uid {
            return Err(format!(
                "IPC socket {} owner mismatch (expected uid {expected_uid})",
                sock.display()
            ));
        }
        Ok(())
    })();
    if let Err(error) = secure {
        drop(listener);
        if let Err(cleanup_error) = std::fs::remove_file(sock) {
            if cleanup_error.kind() != std::io::ErrorKind::NotFound {
                return Err(format!(
                    "{error}; cleanup insecure IPC socket {}: {cleanup_error}",
                    sock.display()
                ));
            }
        }
        return Err(error);
    }
    Ok(listener)
}

#[cfg(unix)]
pub async fn run_ipc_server(
    data_dir: PathBuf,
    forward_path: Option<PathBuf>,
) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;
    let forward = Arc::new(Mutex::new(match forward_path {
        Some(path) => Some(
            ForwardQueue::open(&path)
                .map_err(|error| format!("open forward queue {}: {error}", path.display()))?,
        ),
        None => None,
    }));
    let sock = socket_path(&data_dir);
    let listener = bind_secure_unix_listener(&sock)?;
    eprintln!("raven-node ipc: listening {}", sock.display());

    let data_dir = Arc::new(data_dir);
    let limiter = Arc::new(Semaphore::new(MAX_IPC_CONNECTION_HANDLERS));

    loop {
        let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        if !peer_uid_matches_self(&stream) {
            eprintln!("raven-node ipc: reject peer (uid mismatch)");
            continue;
        }
        let Some(permit) = try_acquire_ipc_handler(&limiter) else {
            eprintln!("raven-node ipc: connection capacity reached");
            drop(stream);
            continue;
        };
        let dd = data_dir.clone();
        let fq = forward.clone();
        tokio::spawn(async move {
            let _permit = permit;
            serve_one(stream, dd, fq).await;
        });
    }
}

#[cfg(windows)]
fn create_windows_pipe(name: &str, first: bool) -> Result<NamedPipeServer, String> {
    let mut security = SameUserSecurityAttributes::new()?;
    let mut options = ServerOptions::new();
    options
        .first_pipe_instance(first)
        .reject_remote_clients(true)
        // One extra instance is the acceptor prepared before the connected
        // instance is handed to its bounded task.
        .max_instances(MAX_IPC_CONNECTION_HANDLERS + 1)
        .in_buffer_size((raven_core::MAX_IPC_FRAME + 4) as u32)
        .out_buffer_size((raven_core::MAX_IPC_FRAME + 4) as u32);
    // SAFETY: `security` owns a valid SECURITY_ATTRIBUTES and self-relative
    // descriptor for the duration of this synchronous CreateNamedPipe call.
    unsafe { options.create_with_security_attributes_raw(name, security.as_mut_void_ptr()) }
        .map_err(|e| format!("create secure named pipe: {e}"))
}

/// Bind the deterministic per-profile Windows named pipe and serve until the
/// process exits. Creation and peer inspection fail closed on any Win32 error.
#[cfg(windows)]
pub async fn run_ipc_server(
    data_dir: PathBuf,
    forward_path: Option<PathBuf>,
) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;
    let forward = Arc::new(Mutex::new(match forward_path {
        Some(path) => Some(
            ForwardQueue::open(&path)
                .map_err(|error| format!("open forward queue {}: {error}", path.display()))?,
        ),
        None => None,
    }));
    let pipe_name = default_named_pipe_name(&data_dir)?;
    let mut listener = create_windows_pipe(&pipe_name, true)?;
    eprintln!("raven-node ipc: listening on protected per-profile named pipe");

    let data_dir = Arc::new(data_dir);
    let limiter = Arc::new(Semaphore::new(MAX_IPC_CONNECTION_HANDLERS));

    loop {
        let permit = limiter
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| "IPC connection limiter closed".to_string())?;
        listener
            .connect()
            .await
            .map_err(|e| format!("named-pipe connect: {e}"))?;

        // Keep a protected instance continuously available. The connected
        // first instance remains alive while this is created, so another
        // process cannot race in as the pipe owner.
        let connected = listener;
        listener = create_windows_pipe(&pipe_name, false)?;
        let dd = data_dir.clone();
        let fq = forward.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(e) = verify_peer_user_and_session(&connected, PipePeer::Client) {
                eprintln!("raven-node ipc: reject Windows peer ({e})");
                return;
            }
            serve_one(connected, dd, fq).await;
        });
    }
}

/// Client helper for same-process smoke tests.
#[allow(dead_code)]
#[cfg(unix)]
pub async fn client_ping(sock: &Path) -> Result<IpcResponse, String> {
    let mut stream = UnixStream::connect(sock)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let req = raven_core::encode_request(&IpcRequest::Ping { v: IPC_VERSION })?;
    stream.write_all(&req).await.map_err(|e| e.to_string())?;
    stream.flush().await.map_err(|e| e.to_string())?;
    let frame = read_frame(&mut stream).await?;
    raven_core::decode_response(&frame)
}

#[cfg(test)]
mod tests {
    use super::*;
    use raven_core::envelope::EnvType;
    use raven_core::identity::Identity;

    #[test]
    fn ipc_handler_admission_is_hard_bounded_and_releases_capacity() {
        let limiter = Arc::new(Semaphore::new(MAX_IPC_CONNECTION_HANDLERS));
        let mut permits = Vec::with_capacity(MAX_IPC_CONNECTION_HANDLERS);
        for _ in 0..MAX_IPC_CONNECTION_HANDLERS {
            permits.push(
                try_acquire_ipc_handler(&limiter)
                    .expect("every configured handler slot must be available once"),
            );
        }
        assert!(
            try_acquire_ipc_handler(&limiter).is_none(),
            "a slow-client burst must not create an unbounded handler task"
        );

        permits.pop();
        assert!(
            try_acquire_ipc_handler(&limiter).is_some(),
            "dropping a completed handler must restore exactly one slot"
        );
    }

    fn sealed_envelope(now: u64, expires_at: u64, marker: u8) -> Envelope {
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [marker; 16],
            routing_tag: [marker.wrapping_add(1); 16],
            dest_device_hint: 0,
            created_at: now.saturating_sub(1),
            expires_at,
            hop_limit: 2,
            replication_budget: 1,
            anti_replay_nonce: [marker.wrapping_add(2); 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: vec![marker; 8],
            sender_authentication: vec![],
        };
        env.sign_with(&Identity::from_seed(&[marker.wrapping_add(3); 32]));
        env
    }

    fn enqueue_request(env: &Envelope) -> IpcRequest {
        IpcRequest::EnqueueSealed {
            v: IPC_VERSION,
            envelope_b64: b64_encode(&env.pack()),
            peer_hint: Some("test-peer".into()),
        }
    }

    #[test]
    fn enqueue_sealed_rejects_exact_expiry_and_preserves_future_signed_expiry() {
        let dir = tempfile::tempdir().unwrap();
        let forward_path = dir.path().join("forward.sqlite");
        let forward = Some(ForwardQueue::open(&forward_path).unwrap());
        let now = 10_000u64;

        let expired = sealed_envelope(now, now, 0xA1);
        let response = handle_req_at(enqueue_request(&expired), dir.path(), &forward, now);
        assert!(matches!(
            response,
            IpcResponse::Error { ref code, .. } if code == "IPC_EXPIRED"
        ));
        assert_eq!(forward.as_ref().unwrap().count_all().unwrap(), 0);
        assert!(!dir.path().join("queue.sqlite").exists());

        let future = sealed_envelope(now, now + 1, 0xA2);
        let digest = authenticated_object_digest(&future);
        assert_eq!(
            handle_req_at(enqueue_request(&future), dir.path(), &forward, now),
            IpcResponse::Accepted { v: IPC_VERSION }
        );
        let stored = forward
            .as_ref()
            .unwrap()
            .get_object(&digest)
            .unwrap()
            .unwrap();
        assert_eq!(stored.expires_at_ms, future.expires_at);
        assert_eq!(stored.packed_envelope, future.pack());
    }

    #[test]
    fn status_bridge_capability_tracks_live_runtime_not_policy_alone() {
        let dir = tempfile::tempdir().unwrap();
        let forward = Some(ForwardQueue::open(&dir.path().join("forward.sqlite")).unwrap());

        let without_listener = handle_req_at(
            IpcRequest::Status { v: IPC_VERSION },
            dir.path(),
            &forward,
            1,
        );
        let IpcResponse::Status { capabilities, .. } = without_listener else {
            panic!("status request did not return status");
        };
        assert!(!capabilities.iter().any(|capability| capability == "bridge"));

        {
            let _runtime = crate::bridge_run::BridgeRuntimeGuard::register(dir.path());
            let with_listener = handle_req_at(
                IpcRequest::Status { v: IPC_VERSION },
                dir.path(),
                &forward,
                1,
            );
            let IpcResponse::Status { capabilities, .. } = with_listener else {
                panic!("status request did not return status");
            };
            assert!(capabilities.iter().any(|capability| capability == "bridge"));
        }

        assert!(!crate::bridge_run::bridge_listener_is_up(dir.path()));
    }

    #[test]
    fn status_storage_error_is_explicitly_unhealthy() {
        let response = build_status_response(
            IPC_VERSION,
            &raven_core::node_policy::NodePolicy::default(),
            true,
            Err("database unavailable".into()),
            false,
            true,
        );
        assert!(matches!(
            response,
            IpcResponse::Error { ref code, ref message, .. }
                if code == "STORAGE" && message == "database unavailable"
        ));
    }

    #[test]
    fn forward_custody_acceptance_survives_optional_outbox_collision() {
        let dir = tempfile::tempdir().unwrap();
        let forward = Some(ForwardQueue::open(&dir.path().join("forward.sqlite")).unwrap());
        let now = 20_000;
        let envelope = sealed_envelope(now, now + 1_000, 0xB1);
        let digest = authenticated_object_digest(&envelope);
        let outbox = OutgoingQueue::open(&dir.path().join("queue.sqlite")).unwrap();
        outbox
            .enqueue(&QueueItem {
                message_id: envelope.message_id,
                packed_envelope: b"preexisting-different-object".to_vec(),
                peer_addr: "test-peer".into(),
                state: DeliveryState::Sent,
                created_at_ms: 1,
            })
            .unwrap();

        assert_eq!(
            handle_req_at(enqueue_request(&envelope), dir.path(), &forward, now),
            IpcResponse::Accepted { v: IPC_VERSION }
        );
        assert_eq!(forward.as_ref().unwrap().count_all().unwrap(), 1);
        assert_eq!(
            forward
                .as_ref()
                .unwrap()
                .get_object(&digest)
                .unwrap()
                .unwrap()
                .packed_envelope,
            envelope.pack()
        );
        let existing = outbox.get(&envelope.message_id).unwrap().unwrap();
        assert_eq!(
            existing.packed_envelope,
            b"preexisting-different-object".to_vec()
        );
        assert_eq!(existing.state, DeliveryState::Sent);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_listener_is_verified_socket_owned_by_self_with_exact_0600_mode() {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};

        let dir = tempfile::tempdir().unwrap();
        let sock = socket_path(dir.path());
        let listener = bind_secure_unix_listener(&sock).unwrap();
        let metadata = std::fs::symlink_metadata(&sock).unwrap();
        assert!(metadata.file_type().is_socket());
        assert_eq!(metadata.mode() & 0o7777, 0o600);
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
        drop(listener);
        std::fs::remove_file(sock).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn forward_queue_open_failure_prevents_ipc_socket_publication() {
        let dir = tempfile::tempdir().unwrap();
        let invalid_forward_path = dir.path().join("forward-is-a-directory");
        std::fs::create_dir(&invalid_forward_path).unwrap();

        let error = run_ipc_server(dir.path().to_path_buf(), Some(invalid_forward_path))
            .await
            .unwrap_err();
        assert!(error.contains("open forward queue"));
        assert!(!socket_path(dir.path()).exists());
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use raven_core::ipc::windows_pipe::{verify_peer_user_and_session, PipePeer};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::windows::named_pipe::ClientOptions;

    use super::*;

    #[tokio::test]
    async fn protected_pipe_authorizes_same_user_session_and_roundtrips() {
        let dir = tempfile::tempdir().unwrap();
        let name = default_named_pipe_name(dir.path()).unwrap();
        let mut server = create_windows_pipe(&name, true).unwrap();
        let mut client = ClientOptions::new().open(&name).unwrap();
        server.connect().await.unwrap();

        verify_peer_user_and_session(&server, PipePeer::Client).unwrap();
        verify_peer_user_and_session(&client, PipePeer::Server).unwrap();

        let request = raven_core::encode_request(&IpcRequest::Ping { v: IPC_VERSION }).unwrap();
        client.write_all(&request).await.unwrap();
        let frame = read_frame(&mut server).await.unwrap();
        assert_eq!(
            raven_core::decode_request(&frame).unwrap(),
            IpcRequest::Ping { v: IPC_VERSION }
        );

        let response = raven_core::encode_response(&IpcResponse::Pong { v: IPC_VERSION }).unwrap();
        server.write_all(&response).await.unwrap();
        let mut len = [0u8; 4];
        client.read_exact(&mut len).await.unwrap();
        let n = u32::from_be_bytes(len) as usize;
        let mut body = vec![0u8; n];
        client.read_exact(&mut body).await.unwrap();
        let mut response_frame = len.to_vec();
        response_frame.extend_from_slice(&body);
        assert_eq!(
            raven_core::decode_response(&response_frame).unwrap(),
            IpcResponse::Pong { v: IPC_VERSION }
        );
    }

    #[tokio::test]
    async fn first_instance_flag_rejects_a_second_pipe_owner() {
        let dir = tempfile::tempdir().unwrap();
        let name = default_named_pipe_name(dir.path()).unwrap();
        let _first = create_windows_pipe(&name, true).unwrap();
        assert!(create_windows_pipe(&name, true).is_err());
    }
}
