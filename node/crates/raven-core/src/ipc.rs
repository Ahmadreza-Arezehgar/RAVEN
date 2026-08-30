//! Local IPC framing for ash/raven ↔ raven-node (UDS / named pipe payload).
//!
//! Versioned length-prefixed JSON requests. Private keys MUST NOT appear in
//! request/response bodies. Auth is peer-cred at the socket layer (OS-specific).

use serde::{Deserialize, Serialize};
#[cfg(any(windows, test))]
use sha2::{Digest, Sha256};

pub const IPC_VERSION: u16 = 1;
pub const MAX_IPC_FRAME: usize = 256 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
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
    if n > MAX_IPC_FRAME || frame.len() != 4 + n {
        return Err("bad length".into());
    }
    let value: serde_json::Value =
        serde_json::from_slice(&frame[4..]).map_err(|e| e.to_string())?;
    if contains_forbidden_secret_field(&value) {
        return Err("forbidden field".into());
    }
    let req: IpcRequest = serde_json::from_value(value).map_err(|e| e.to_string())?;
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
    Ok(req)
}

/// Refuse secret-bearing JSON *field names* without rejecting harmless values
/// such as a peer called `seedling` or sealed/base64 bytes containing those
/// character sequences. Normalization prevents punctuation/case variants from
/// bypassing the defense-in-depth check.
fn contains_forbidden_secret_field(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(fields) => fields.iter().any(|(key, child)| {
            let normalized: String = key
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .map(|c| c.to_ascii_lowercase())
                .collect();
            matches!(
                normalized.as_str(),
                "seed"
                    | "privkey"
                    | "privatekey"
                    | "secretkey"
                    | "plaintext"
                    | "recovery"
                    | "recoveryphrase"
                    | "mnemonic"
            ) || contains_forbidden_secret_field(child)
        }),
        serde_json::Value::Array(items) => items.iter().any(contains_forbidden_secret_field),
        _ => false,
    }
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
    if n > MAX_IPC_FRAME || frame.len() != 4 + n {
        return Err("bad length".into());
    }
    serde_json::from_slice(&frame[4..4 + n]).map_err(|e| e.to_string())
}

/// Default socket path under data dir (mode 0600 expected at bind).
pub fn default_socket_path(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join("raven-node.sock")
}

#[cfg(any(windows, test))]
fn named_pipe_name_from_profile_key(profile_key: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b"raven/ipc/named-pipe/v1\0");
    h.update(profile_key);
    let digest = h.finalize();
    format!(r"\\.\pipe\raven-node-{}", hex::encode(&digest[..16]))
}

/// Deterministic, per-profile Windows pipe name.
///
/// The canonical profile path is hashed, so the public object name contains no
/// identity, seed, username, or plaintext. Both endpoints must already be able
/// to resolve the profile directory; failure is deliberately fail-closed.
#[cfg(windows)]
pub fn default_named_pipe_name(data_dir: &std::path::Path) -> Result<String, String> {
    use std::os::windows::ffi::OsStrExt;

    let canonical =
        std::fs::canonicalize(data_dir).map_err(|e| format!("canonicalize IPC profile: {e}"))?;
    let mut key = Vec::new();
    for word in canonical.as_os_str().encode_wide() {
        key.extend_from_slice(&word.to_le_bytes());
    }
    Ok(named_pipe_name_from_profile_key(&key))
}

/// Windows named-pipe authorization helpers shared by raven-node and ash.
///
/// The object DACL is restricted to the current process user. After connect,
/// each endpoint also verifies the peer process token SID and Windows session.
/// Any Win32 lookup failure rejects the peer.
#[cfg(windows)]
pub mod windows_pipe {
    use std::ffi::c_void;
    use std::io;
    use std::mem::{size_of, size_of_val};
    use std::os::windows::io::AsRawHandle;
    use std::ptr::null_mut;

    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{
        EqualSid, GetTokenInformation, IsValidSid, TokenUser, PSECURITY_DESCRIPTOR,
        SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Pipes::{
        GetNamedPipeClientProcessId, GetNamedPipeClientSessionId, GetNamedPipeServerProcessId,
        GetNamedPipeServerSessionId,
    };
    use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum PipePeer {
        Client,
        Server,
    }

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: this wrapper is constructed only from an owned handle
                // returned by OpenProcess/OpenProcessToken and drops it once.
                unsafe {
                    CloseHandle(self.0);
                }
            }
        }
    }

    fn last_error(context: &str) -> String {
        format!("{context}: {}", io::Error::last_os_error())
    }

    fn token_user_buffer(process: HANDLE) -> Result<Vec<usize>, String> {
        let mut raw_token: HANDLE = null_mut();
        // SAFETY: raw_token is a valid out pointer; process is either the
        // current-process pseudo handle or an owned process handle.
        if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut raw_token) } == 0 {
            return Err(last_error("OpenProcessToken"));
        }
        let token = OwnedHandle(raw_token);

        let mut needed = 0u32;
        // The sizing call is expected to fail with INSUFFICIENT_BUFFER while
        // returning the required byte count. We only proceed with a nonzero,
        // bounded size and validate the second call independently.
        unsafe {
            GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut needed);
        }
        if needed == 0 || needed as usize > 64 * 1024 {
            return Err(last_error("GetTokenInformation(TokenUser) size"));
        }
        let words = (needed as usize).div_ceil(size_of::<usize>());
        let mut buffer = vec![0usize; words];
        let capacity = size_of_val(buffer.as_slice());
        let capacity = u32::try_from(capacity).map_err(|_| "token buffer too large".to_string())?;
        // SAFETY: Vec<usize> provides pointer alignment suitable for TOKEN_USER
        // and capacity is at least the byte count requested by Win32.
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                buffer.as_mut_ptr().cast(),
                capacity,
                &mut needed,
            )
        } == 0
        {
            return Err(last_error("GetTokenInformation(TokenUser)"));
        }
        let token_user = unsafe { &*(buffer.as_ptr().cast::<TOKEN_USER>()) };
        if token_user.User.Sid.is_null() || unsafe { IsValidSid(token_user.User.Sid) } == 0 {
            return Err("GetTokenInformation returned an invalid user SID".into());
        }
        Ok(buffer)
    }

    fn user_sid(buffer: &[usize]) -> windows_sys::Win32::Security::PSID {
        // SAFETY: buffers are created and validated by token_user_buffer and
        // remain alive for every use of the returned pointer.
        unsafe { (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid }
    }

    fn current_user_sid_string() -> Result<String, String> {
        // SAFETY: GetCurrentProcess returns a non-owning pseudo handle valid in
        // this process; token_user_buffer does not close it.
        let buffer = token_user_buffer(unsafe { GetCurrentProcess() })?;
        let mut text_ptr = null_mut();
        // SAFETY: the SID was validated and text_ptr is a valid out pointer.
        if unsafe { ConvertSidToStringSidW(user_sid(&buffer), &mut text_ptr) } == 0 {
            return Err(last_error("ConvertSidToStringSidW"));
        }
        if text_ptr.is_null() {
            return Err("ConvertSidToStringSidW returned null".into());
        }
        let mut len = 0usize;
        // A textual SID is tiny; the bound prevents an unbounded scan if a
        // malformed platform result were ever returned.
        while len < 512 && unsafe { *text_ptr.add(len) } != 0 {
            len += 1;
        }
        let result = if len == 512 {
            Err("current user SID string was not terminated".into())
        } else {
            // SAFETY: text_ptr points to at least len initialized UTF-16 words.
            Ok(String::from_utf16_lossy(unsafe {
                std::slice::from_raw_parts(text_ptr, len)
            }))
        };
        // SAFETY: ConvertSidToStringSidW allocates with LocalAlloc.
        unsafe {
            LocalFree(text_ptr.cast());
        }
        result
    }

    /// Owns the self-relative security descriptor referenced by `attrs`.
    pub struct SameUserSecurityAttributes {
        descriptor: PSECURITY_DESCRIPTOR,
        attrs: SECURITY_ATTRIBUTES,
    }

    impl SameUserSecurityAttributes {
        pub fn new() -> Result<Self, String> {
            let sid = current_user_sid_string()?;
            // Protected DACL; only this exact user SID receives access. Remote
            // clients are rejected separately by the pipe creation flags.
            let sddl = format!("O:{sid}D:P(A;;GA;;;{sid})");
            let wide: Vec<u16> = sddl.encode_utf16().chain(std::iter::once(0)).collect();
            let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
            // SAFETY: wide is NUL-terminated and descriptor is a valid out ptr.
            if unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    wide.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            } == 0
            {
                return Err(last_error(
                    "ConvertStringSecurityDescriptorToSecurityDescriptorW",
                ));
            }
            if descriptor.is_null() {
                return Err("security descriptor conversion returned null".into());
            }
            let attrs = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            };
            Ok(Self { descriptor, attrs })
        }

        /// Pointer remains valid until this owner is dropped. The Win32 pipe
        /// creation call consumes the attributes synchronously.
        pub fn as_mut_void_ptr(&mut self) -> *mut c_void {
            (&mut self.attrs as *mut SECURITY_ATTRIBUTES).cast()
        }
    }

    impl Drop for SameUserSecurityAttributes {
        fn drop(&mut self) {
            if !self.descriptor.is_null() {
                // SAFETY: descriptor was allocated by the SDDL conversion API
                // and is freed exactly once after CreateNamedPipe returns.
                unsafe {
                    LocalFree(self.descriptor.cast());
                }
            }
        }
    }

    /// Verify that the connected pipe peer belongs to our process user SID and
    /// our current Windows session. This supplements (and never replaces) the
    /// current-user-only server DACL.
    pub fn verify_peer_user_and_session<T>(pipe: &T, peer: PipePeer) -> Result<(), String>
    where
        T: AsRawHandle,
    {
        let pipe = pipe.as_raw_handle();
        if pipe.is_null() {
            return Err("named-pipe handle is null".into());
        }
        let mut peer_pid = 0u32;
        let mut peer_session = 0u32;
        // SAFETY: pipe is a live named-pipe handle and both outputs are valid.
        let (pid_ok, session_ok) = unsafe {
            match peer {
                PipePeer::Client => (
                    GetNamedPipeClientProcessId(pipe, &mut peer_pid),
                    GetNamedPipeClientSessionId(pipe, &mut peer_session),
                ),
                PipePeer::Server => (
                    GetNamedPipeServerProcessId(pipe, &mut peer_pid),
                    GetNamedPipeServerSessionId(pipe, &mut peer_session),
                ),
            }
        };
        if pid_ok == 0 || peer_pid == 0 {
            return Err(last_error("named-pipe peer process lookup"));
        }
        if session_ok == 0 {
            return Err(last_error("named-pipe peer session lookup"));
        }

        let mut self_session = 0u32;
        // SAFETY: self_session is a valid out pointer.
        if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut self_session) } == 0 {
            return Err(last_error("current process session lookup"));
        }
        if peer_session != self_session {
            return Err("named-pipe peer Windows session mismatch".into());
        }

        // SAFETY: OpenProcess returns an owned handle or null. Access is read-
        // only and intentionally fails closed for protected/inaccessible peers.
        let raw_peer = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, peer_pid) };
        if raw_peer.is_null() {
            return Err(last_error("OpenProcess(named-pipe peer)"));
        }
        let peer_process = OwnedHandle(raw_peer);
        let peer_user = token_user_buffer(peer_process.0)?;
        let self_user = token_user_buffer(unsafe { GetCurrentProcess() })?;
        // SAFETY: both SID pointers are validated and their backing buffers are
        // alive for the duration of EqualSid.
        if unsafe { EqualSid(user_sid(&peer_user), user_sid(&self_user)) } == 0 {
            return Err("named-pipe peer user SID mismatch".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame_json(body: &[u8]) -> Vec<u8> {
        let mut frame = Vec::with_capacity(4 + body.len());
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(body);
        frame
    }

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
        assert_eq!(
            decode_request(&frame_json(body)).unwrap_err(),
            "forbidden field"
        );
    }

    #[test]
    fn rejects_normalized_or_nested_secret_field_names() {
        for body in [
            br#"{"op":"ping","v":1,"Private-Key":"nope"}"#.as_slice(),
            br#"{"op":"ping","v":1,"extension":{"recovery_phrase":"nope"}}"#.as_slice(),
        ] {
            assert_eq!(
                decode_request(&frame_json(body)).unwrap_err(),
                "forbidden field"
            );
        }
    }

    #[test]
    fn permits_secret_words_inside_non_secret_values() {
        let req = IpcRequest::EnqueueSealed {
            v: IPC_VERSION,
            envelope_b64: "c2VlZA==".into(),
            peer_hint: Some("seedling-recovery-route".into()),
        };
        assert_eq!(decode_request(&encode_request(&req).unwrap()).unwrap(), req);
    }

    #[test]
    fn rejects_trailing_bytes_after_declared_frame() {
        let mut frame = encode_request(&IpcRequest::Ping { v: IPC_VERSION }).unwrap();
        frame.push(b' ');
        assert_eq!(decode_request(&frame).unwrap_err(), "bad length");

        let mut response = encode_response(&IpcResponse::Pong { v: IPC_VERSION }).unwrap();
        response.push(b' ');
        assert_eq!(decode_response(&response).unwrap_err(), "bad length");
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
    fn named_pipe_profile_name_is_deterministic_and_domain_separated() {
        let a1 = named_pipe_name_from_profile_key(b"C:\\Users\\alice\\Raven");
        let a2 = named_pipe_name_from_profile_key(b"C:\\Users\\alice\\Raven");
        let b = named_pipe_name_from_profile_key(b"C:\\Users\\alice\\Raven-2");
        assert_eq!(a1, a2);
        assert_ne!(a1, b);
        assert!(a1.starts_with(r"\\.\pipe\raven-node-"));
        assert_eq!(a1.len(), r"\\.\pipe\raven-node-".len() + 32);
        assert!(!a1.to_ascii_lowercase().contains("alice"));
    }
}
