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
use raven_core::node_policy::{load_policy, save_policy};
use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use raven_core::transport::TransportKind;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
#[cfg(windows)]
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
#[cfg(windows)]
use tokio::sync::Semaphore;

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

fn handle_req(req: IpcRequest, data_dir: &Path, forward: &Option<ForwardQueue>) -> IpcResponse {
    match req {
        IpcRequest::Ping { v } => IpcResponse::Pong { v },
        IpcRequest::Status { v } => {
            let policy = load_policy(data_dir);
            let (pending, caps) = match forward {
                Some(q) => (q.count_pending().unwrap_or(0) as u64, {
                    let mut c = vec!["ipc".into()];
                    if crate::lan_direct::listener_is_up() {
                        c.push("lan_direct".into());
                    }
                    if policy.bridge {
                        c.push("bridge".into());
                    }
                    if policy.store {
                        c.push("store".into());
                    }
                    if policy.relay {
                        c.push("relay".into());
                    }
                    c
                }),
                None => (0u64, vec!["ipc".into()]),
            };
            IpcResponse::Status {
                v,
                bridge: policy.bridge,
                store: policy.store,
                relay: policy.relay,
                forward_pending: pending,
                capabilities: caps,
            }
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
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let peer = peer_hint.unwrap_or_else(|| "ipc".into());
            // Prefer forward queue when available (always-on bridge); also mirror outbox.
            if let Some(q) = forward {
                let item = ForwardItem {
                    object_digest: authenticated_object_digest(&env),
                    message_id: env.message_id,
                    packed_envelope: packed.clone(),
                    ingress: TransportKind::Internet,
                    egress: TransportKind::Internet,
                    state: ForwardState::Queued,
                    created_at_ms: now,
                    expires_at_ms: env.expires_at.max(now.saturating_add(60_000)),
                    previous_hop: peer.clone(),
                };
                if let Err(e) = q.enqueue(&item) {
                    return IpcResponse::Error {
                        v,
                        code: "QUEUE_FULL".into(),
                        message: e.to_string(),
                    };
                }
            }
            let outbox_path = data_dir.join("queue.sqlite");
            match OutgoingQueue::open(&outbox_path) {
                Ok(oq) => {
                    let item = QueueItem {
                        message_id: env.message_id,
                        packed_envelope: packed,
                        peer_addr: peer,
                        state: DeliveryState::Queued,
                        created_at_ms: now,
                    };
                    if let Err(e) = oq.enqueue(&item) {
                        return IpcResponse::Error {
                            v,
                            code: "OUTBOX".into(),
                            message: e.to_string(),
                        };
                    }
                }
                Err(e) => {
                    return IpcResponse::Error {
                        v,
                        code: "OUTBOX".into(),
                        message: e.to_string(),
                    };
                }
            }
            IpcResponse::Accepted { v }
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
pub async fn run_ipc_server(
    data_dir: PathBuf,
    forward_path: Option<PathBuf>,
) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;
    let sock = socket_path(&data_dir);
    if sock.exists() {
        let _ = std::fs::remove_file(&sock);
    }
    let listener =
        UnixListener::bind(&sock).map_err(|e| format!("bind {}: {e}", sock.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o600));
    }
    eprintln!("raven-node ipc: listening {}", sock.display());

    let forward = Arc::new(Mutex::new(match forward_path {
        Some(p) => ForwardQueue::open(&p).ok(),
        None => None,
    }));
    let data_dir = Arc::new(data_dir);

    loop {
        let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        if !peer_uid_matches_self(&stream) {
            eprintln!("raven-node ipc: reject peer (uid mismatch)");
            continue;
        }
        let dd = data_dir.clone();
        let fq = forward.clone();
        tokio::spawn(async move {
            serve_one(stream, dd, fq).await;
        });
    }
}

#[cfg(windows)]
const MAX_WINDOWS_IPC_HANDLERS: usize = 32;

#[cfg(windows)]
fn create_windows_pipe(name: &str, first: bool) -> Result<NamedPipeServer, String> {
    let mut security = SameUserSecurityAttributes::new()?;
    let mut options = ServerOptions::new();
    options
        .first_pipe_instance(first)
        .reject_remote_clients(true)
        // One extra instance is the acceptor prepared before the connected
        // instance is handed to its bounded task.
        .max_instances(MAX_WINDOWS_IPC_HANDLERS + 1)
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
    let pipe_name = default_named_pipe_name(&data_dir)?;
    let mut listener = create_windows_pipe(&pipe_name, true)?;
    eprintln!("raven-node ipc: listening on protected per-profile named pipe");

    let forward = Arc::new(Mutex::new(match forward_path {
        Some(p) => ForwardQueue::open(&p).ok(),
        None => None,
    }));
    let data_dir = Arc::new(data_dir);
    let limiter = Arc::new(Semaphore::new(MAX_WINDOWS_IPC_HANDLERS));

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
