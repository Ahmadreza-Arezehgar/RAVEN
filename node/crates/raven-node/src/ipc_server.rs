//! Unix domain socket IPC server (macOS/Linux).
//!
//! Auth model (V1): socket path under the caller's data dir, mode `0600`,
//! removed/rebound on start. Same-UID filesystem permissions are the gate;
//! requests still refuse secret field names (`raven_core::ipc`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use raven_core::forward_queue::ForwardQueue;
use raven_core::ipc::{
    decode_request, default_socket_path, encode_response, IpcRequest, IpcResponse, IPC_VERSION,
};
use raven_core::node_policy::{load_policy, save_policy};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;

pub fn socket_path(data_dir: &Path) -> PathBuf {
    default_socket_path(data_dir)
}

async fn read_frame(stream: &mut UnixStream) -> Result<Vec<u8>, String> {
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
}

fn handle_req(req: IpcRequest, data_dir: &Path, forward: &Option<ForwardQueue>) -> IpcResponse {
    match req {
        IpcRequest::Ping { v } => IpcResponse::Pong { v },
        IpcRequest::Status { v } => {
            let policy = load_policy(data_dir);
            let (pending, caps) = match forward {
                Some(q) => (
                    q.count_pending().unwrap_or(0) as u64,
                    {
                        let mut c = vec!["ipc".into()];
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
                    },
                ),
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
        IpcRequest::EnqueueSealed { v, envelope_b64, .. } => {
            if envelope_b64.len() > 512 * 1024 {
                return IpcResponse::Error {
                    v,
                    code: "IPC_FRAME".into(),
                    message: "envelope too large".into(),
                };
            }
            // Accept framing only — sealed bytes may be queued by future daemon paths.
            IpcResponse::Accepted { v }
        }
    }
}

async fn serve_one(mut stream: UnixStream, data_dir: Arc<PathBuf>, forward: Arc<Mutex<Option<ForwardQueue>>>) {
    let frame = match read_frame(&mut stream).await {
        Ok(f) => f,
        Err(_) => return,
    };
    let fwd = forward.lock().await;
    let resp = match decode_request(&frame) {
        Ok(req) => handle_req(req, &data_dir, &fwd),
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
    drop(fwd);
    if let Ok(out) = encode_response(&resp) {
        let _ = stream.write_all(&out).await;
        let _ = stream.flush().await;
    }
}

/// Bind UDS with mode 0600 and serve until the process exits.
pub async fn run_ipc_server(
    data_dir: PathBuf,
    forward_path: Option<PathBuf>,
) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;
    let sock = socket_path(&data_dir);
    if sock.exists() {
        let _ = std::fs::remove_file(&sock);
    }
    let listener = UnixListener::bind(&sock).map_err(|e| format!("bind {}: {e}", sock.display()))?;
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
        let dd = data_dir.clone();
        let fq = forward.clone();
        tokio::spawn(async move {
            serve_one(stream, dd, fq).await;
        });
    }
}

/// Client helper for same-process smoke tests.
#[allow(dead_code)]
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
