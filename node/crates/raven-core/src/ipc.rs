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
    Ping { v: u16 },
    Status { v: u16 },
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "ok", rename_all = "snake_case")]
pub enum IpcResponse {
    Pong { v: u16 },
    Status {
        v: u16,
        bridge: bool,
        store: bool,
        relay: bool,
        forward_pending: u64,
        capabilities: Vec<String>,
    },
    Accepted { v: u16 },
    Error { v: u16, code: String, message: String },
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
        | IpcRequest::EnqueueSealed { v, .. } => {
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

/// Default socket path under data dir (mode 0600 expected at bind).
pub fn default_socket_path(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join("raven-node.sock")
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
}
