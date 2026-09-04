//! Local IPC framing for ash/raven ↔ raven-node (UDS / named pipe payload).
//!
//! Versioned length-prefixed JSON requests. Private keys MUST NOT appear in
//! request/response bodies. Auth is peer-cred at the socket layer (OS-specific).

use serde::{Deserialize, Serialize};

pub const IPC_VERSION: u16 = 1;
pub const MAX_IPC_FRAME: usize = 256 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum IpcRequest {
    Ping {
        v: u16,
    },
    Status {
        v: u16,
    },
    /// Policy toggle — no secrets.
    SetPolicy {
        v: u16,
        bridge: Option<bool>,
        store: Option<bool>,
        relay: Option<bool>,
    },
    /// Enqueue already-sealed RavenEnvelopeV1 (base64). Daemon never seals from plaintext here.
    EnqueueSealed {
        v: u16,
        envelope_b64: String,
        peer_hint: Option<String>,
    },
    /// Direct-dial a LAN peer over Noise XX and exchange already-sealed frames.
    LanDial {
        v: u16,
        lan_dial: String,
        expected_pub_hex: String,
        frames_b64: Vec<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "ok", rename_all = "snake_case")]
pub enum IpcResponse {
    Pong {
        v: u16,
    },
    Status {
        v: u16,
        bridge: bool,
        store: bool,
        relay: bool,
        forward_pending: u64,
        capabilities: Vec<String>,
    },
    Accepted {
        v: u16,
    },
    LanDialResult {
        v: u16,
        frames_b64: Vec<String>,
    },
    Error {
        v: u16,
        code: String,
        message: String,
    },
}

pub fn encode_request(req: &IpcRequest) -> Result<Vec<u8>, String> {
    let body = serde_json::to_vec(req).map_err(|e| e.to_string())?;
    if body.len() > MAX_IPC_FRAME {
        return Err("ipc request too large".into());
    }
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn decode_request(frame: &[u8]) -> Result<IpcRequest, String> {
    if frame.len() < 4 {
        return Err("short frame".into());
    }
    let n = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
    if n > MAX_IPC_FRAME || frame.len() < 4 + n {
        return Err("bad length".into());
    }
    let req: IpcRequest = serde_json::from_slice(&frame[4..4 + n]).map_err(|e| e.to_string())?;
    match &req {
        IpcRequest::Ping { v }
        | IpcRequest::Status { v }
        | IpcRequest::SetPolicy { v, .. }
        | IpcRequest::EnqueueSealed { v, .. }
        | IpcRequest::LanDial { v, .. } => {
            if *v != IPC_VERSION {
                return Err("ipc version".into());
            }
        }
    }
    // Refuse accidental secret field names in JSON (defense in depth).
    let raw = std::str::from_utf8(&frame[4..4 + n]).unwrap_or("");
    for bad in ["seed", "private_key", "plaintext", "recovery"] {
        if raw.to_ascii_lowercase().contains(bad) {
            return Err("forbidden field".into());
        }
    }
    Ok(req)
}

pub fn encode_response(resp: &IpcResponse) -> Result<Vec<u8>, String> {
    let body = serde_json::to_vec(resp).map_err(|e| e.to_string())?;
    if body.len() > MAX_IPC_FRAME {
        return Err("ipc response too large".into());
    }
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn decode_response(frame: &[u8]) -> Result<IpcResponse, String> {
    if frame.len() < 4 {
        return Err("short frame".into());
    }
    let n = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
    if n > MAX_IPC_FRAME || frame.len() < 4 + n {
        return Err("bad length".into());
    }
    serde_json::from_slice(&frame[4..4 + n]).map_err(|e| e.to_string())
}

/// Default UDS path under data dir (mode 0600 expected at bind). Unix only for
/// presence probes — Windows doctor must not use this (false-red).
pub fn default_socket_path(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join("raven-node.sock")
}

/// Canonical Windows named-pipe bind/connect name.
/// Windows Platform server MUST bind this exact string (user DACL only).
/// Framing is the same length-prefixed JSON as UDS (`encode_request` / `decode_response`).
pub const WINDOWS_NAMED_PIPE: &str = r"\\.\pipe\raven-node";

/// Alias for [`WINDOWS_NAMED_PIPE`] (Windows Platform bind name).
pub fn default_pipe_name() -> &'static str {
    WINDOWS_NAMED_PIPE
}

/// Local IPC endpoint for this OS: UDS under `data_dir`, or `WINDOWS_NAMED_PIPE`.
pub fn default_ipc_endpoint(data_dir: &std::path::Path) -> std::path::PathBuf {
    #[cfg(windows)]
    {
        let _ = data_dir;
        std::path::PathBuf::from(WINDOWS_NAMED_PIPE)
    }
    #[cfg(not(windows))]
    {
        default_socket_path(data_dir)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_ping() {
        let req = IpcRequest::Ping { v: IPC_VERSION };
        let f = encode_request(&req).unwrap();
        assert_eq!(decode_request(&f).unwrap(), req);
        let resp = IpcResponse::Pong { v: IPC_VERSION };
        let rf = encode_response(&resp).unwrap();
        assert_eq!(decode_response(&rf).unwrap(), resp);
    }

    #[test]
    fn rejects_secret_token_in_json() {
        let body = br#"{"op":"ping","v":1,"seed":"nope"}"#;
        let mut frame = Vec::new();
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(body);
        assert!(decode_request(&frame).is_err());
    }

    #[test]
    fn rejects_oversized() {
        let huge = vec![b'a'; MAX_IPC_FRAME + 10];
        let mut frame = Vec::new();
        frame.extend_from_slice(&(huge.len() as u32).to_be_bytes());
        frame.extend_from_slice(&huge);
        assert!(decode_request(&frame).is_err());
    }

    #[test]
    fn roundtrip_lan_dial() {
        let req = IpcRequest::LanDial {
            v: IPC_VERSION,
            lan_dial: "192.168.1.20:7420".into(),
            expected_pub_hex: "ab".repeat(32),
            frames_b64: vec!["QUJD".into()],
        };
        let f = encode_request(&req).unwrap();
        assert_eq!(decode_request(&f).unwrap(), req);
        let resp = IpcResponse::LanDialResult {
            v: IPC_VERSION,
            frames_b64: vec!["ZGVm".into()],
        };
        let rf = encode_response(&resp).unwrap();
        assert_eq!(decode_response(&rf).unwrap(), resp);
    }

    #[test]
    fn windows_named_pipe_is_canonical_bind_name() {
        assert_eq!(WINDOWS_NAMED_PIPE, r"\\.\pipe\raven-node");
        assert_eq!(default_pipe_name(), WINDOWS_NAMED_PIPE);
        let dir = std::path::Path::new("/tmp/raven-data");
        let ep = default_ipc_endpoint(dir);
        #[cfg(windows)]
        {
            assert_eq!(ep.to_string_lossy(), WINDOWS_NAMED_PIPE);
            assert!(!ep.to_string_lossy().contains("raven-node.sock"));
        }
        #[cfg(not(windows))]
        {
            assert_eq!(ep, default_socket_path(dir));
            assert!(ep.ends_with("raven-node.sock"));
        }
    }
}
