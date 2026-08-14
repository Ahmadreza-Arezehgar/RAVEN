//! Test A lab: PairInit over LAN OOB + IndexedSessionStore outbound.
//!
//! Activated only when `RAVEN_LAB_TEST_A=1` (debug). Never uses
//! `unsafe-demo-crypto` / public-key-derived `seal_message`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use rand::rngs::OsRng;
use rand::RngCore;
use raven_core::address::encode_address;
use raven_core::atsam_mlkem::{begin_hybrid_initiation, HybridKeypair};
use raven_core::device_cert::{
    load_device_registry, save_device_registry, DeviceCertificate, DeviceRegistry,
};
use raven_core::identity::Identity;
use raven_core::indexed_session_store::{
    AuthorizedEndpointDevice, IndexedSessionRecordKey, IndexedSessionStore, LocalRole,
};
use raven_core::internet::deframe_prefix;
use raven_core::ipc::{default_socket_path, IpcRequest, IpcResponse, IPC_VERSION};
use raven_core::pair_init::{
    device_certificate_hash, encode_init, init_signing_bytes, prekey_bundle_hash, session_id,
    transcript_hash, PairInit, PairInitTrust, PairResponse,
};
use raven_core::pair_init_lan_oob::{
    classify_packed_envelope, wrap_oob_wire, PairInitOobClassify, PairInitOobKind,
};
use raven_core::prekey_bundle::PrekeyStore;
use raven_core::sanitize::sanitize_terminal_text;

use super::trace_delivery;

const C_DIM: &str = "\x1b[38;2;160;160;170m";
const C_GREEN: &str = "\x1b[38;2;34;197;94m";
const C_RESET: &str = "\x1b[0m";
const C_BOLD: &str = "\x1b[1m";

const DEVICE_ID: &str = "ash-lab-primary";
const DEVICE_X_SECRET: &str = "lab_device_x25519.secret";
const DEVICE_X_PUBLIC: &str = "lab_device_x25519.pub";
const PEER_CERT_CACHE: &str = "peer_device_certs.json";

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn parse_pub_hex(s: &str) -> Result<[u8; 32], String> {
    let h = s.trim().to_lowercase();
    if h.len() != 64 {
        return Err("pub_hex must be 64 hex chars".into());
    }
    let v = hex::decode(&h).map_err(|_| "pub_hex invalid hex".to_string())?;
    if v.len() != 32 {
        return Err("pub_hex must decode to 32 bytes".into());
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

struct PendingLabInit {
    init: PairInit,
    record_key: IndexedSessionRecordKey,
}

fn pending_inits() -> &'static Mutex<HashMap<[u8; 16], PendingLabInit>> {
    static MAP: OnceLock<Mutex<HashMap<[u8; 16], PendingLabInit>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

fn ensure_device_x25519(data_dir: &Path) -> Result<[u8; 32], String> {
    let secret_path = data_dir.join(DEVICE_X_SECRET);
    let public_path = data_dir.join(DEVICE_X_PUBLIC);
    if secret_path.exists() && public_path.exists() {
        let pub_raw = std::fs::read(&public_path).map_err(|e| e.to_string())?;
        if pub_raw.len() != 32 {
            return Err("device_x.pub length".into());
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&pub_raw);
        return Ok(out);
    }
    let mut kp = HybridKeypair::generate(&mut OsRng);
    let secret = kp.x25519_secret;
    let public = kp.x25519_public;
    kp.x25519_secret = [0u8; 32];
    std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
    std::fs::write(&secret_path, secret).map_err(|e| e.to_string())?;
    std::fs::write(&public_path, public).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&secret_path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(public)
}

fn ensure_local_device_cert(
    data_dir: &Path,
    id: &Identity,
) -> Result<(DeviceCertificate, DeviceRegistry), String> {
    let mut reg = load_device_registry(data_dir);
    let now = now_ms();
    if let Some(existing) = reg.certs.get(DEVICE_ID).cloned() {
        if existing.device_ed_pub == id.public_key_bytes() && existing.verify(now).is_ok() {
            return Ok((existing, reg));
        }
    }
    let x_pub = ensure_device_x25519(data_dir)?;
    let cert = DeviceCertificate::issue(
        id,
        id.public_key_bytes(),
        x_pub,
        DEVICE_ID,
        now.saturating_sub(60_000),
        now.saturating_add(365 * 24 * 3600 * 1000),
        0,
    )?;
    reg.add(cert.clone(), now)?;
    save_device_registry(data_dir, &reg)?;
    Ok((cert, reg))
}

fn load_peer_cert(data_dir: &Path, peer_pub: &[u8; 32]) -> Result<DeviceCertificate, String> {
    let path = data_dir.join(PEER_CERT_CACHE);
    if !path.exists() {
        return Err(
            "peer device cert missing — import with lab-import-peer-cert (peer_device_certs.json)"
                .into(),
        );
    }
    let raw = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let map: HashMap<String, DeviceCertificate> =
        serde_json::from_str(&raw).map_err(|e| format!("peer cert cache: {e}"))?;
    let key = hex::encode(peer_pub);
    map.get(&key)
        .cloned()
        .ok_or_else(|| format!("no peer cert for {key}"))
}

fn cache_peer_cert(
    data_dir: &Path,
    peer_pub: &[u8; 32],
    cert: &DeviceCertificate,
) -> Result<(), String> {
    let path = data_dir.join(PEER_CERT_CACHE);
    let mut map: HashMap<String, DeviceCertificate> = if path.exists() {
        serde_json::from_str(&std::fs::read_to_string(&path).map_err(|e| e.to_string())?)
            .unwrap_or_default()
    } else {
        HashMap::new()
    };
    map.insert(hex::encode(peer_pub), cert.clone());
    let out = serde_json::to_string_pretty(&map).map_err(|e| e.to_string())?;
    std::fs::write(path, out).map_err(|e| e.to_string())
}

fn ipc_enqueue(data_dir: &Path, packed: &[u8], peer_hint: &str) -> Result<(), String> {
    use base64::Engine;
    let sock = default_socket_path(data_dir);
    if !sock.exists() {
        return Err("IPC socket missing — start Mac LAN daemon first".into());
    }
    let b64 = base64::engine::general_purpose::STANDARD.encode(packed);
    let req = IpcRequest::EnqueueSealed {
        v: IPC_VERSION,
        envelope_b64: b64,
        peer_hint: Some(peer_hint.to_string()),
    };
    #[cfg(unix)]
    {
        use raven_core::ipc::{decode_response, encode_request};
        use std::os::unix::net::UnixStream;
        let mut stream =
            UnixStream::connect(&sock).map_err(|e| format!("ipc connect: {e}"))?;
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
        let frame = encode_request(&req).map_err(|e| format!("ipc encode: {e}"))?;
        stream
            .write_all(&frame)
            .map_err(|e| format!("ipc write: {e}"))?;
        let mut len_buf = [0u8; 4];
        stream
            .read_exact(&mut len_buf)
            .map_err(|e| format!("ipc read len: {e}"))?;
        let n = u32::from_be_bytes(len_buf) as usize;
        if n == 0 || n > raven_core::MAX_IPC_FRAME {
            return Err("IPC_FRAME".into());
        }
        let mut body = vec![0u8; n];
        stream
            .read_exact(&mut body)
            .map_err(|e| format!("ipc read body: {e}"))?;
        let mut resp_frame = Vec::with_capacity(4 + n);
        resp_frame.extend_from_slice(&len_buf);
        resp_frame.extend_from_slice(&body);
        match decode_response(&resp_frame).map_err(|e| format!("ipc decode: {e}"))? {
            IpcResponse::Accepted { .. } => Ok(()),
            IpcResponse::Error { code, message, .. } => Err(format!("ipc {code}: {message}")),
            other => Err(format!("unexpected ipc: {other:?}")),
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (data_dir, packed, peer_hint, req);
        Err("IPC UDS unavailable".into())
    }
}

pub fn ensure_lab_local_material(data_dir: &Path, id: &Identity) -> Result<(), String> {
    let (_cert, _reg) = ensure_local_device_cert(data_dir, id)?;
    let store = PrekeyStore::load(data_dir);
    let now = now_ms();
    if store
        .fetch(&id.public_key_bytes(), now)
        .ok()
        .flatten()
        .is_some()
    {
        return Ok(());
    }
    Err("local prekey missing — run `ash prekey publish` before PairInit".into())
}

/// Create verified PairInit, enqueue on LAN, wait PairResponse, send indexed text.
pub fn run_pair_init_and_send(
    data_dir: &Path,
    id: &Identity,
    peer: &str,
    peer_pub_hex: &str,
    text: &str,
) -> Result<(), String> {
    if !trace_delivery::live_pair_init_outbound_ready() {
        return Err(trace_delivery::production_gate_status().into());
    }
    ensure_lab_local_material(data_dir, id)?;
    let peer_pub = parse_pub_hex(peer_pub_hex)?;
    let now = now_ms();

    let (local_cert, registry) = ensure_local_device_cert(data_dir, id)?;
    let peer_cert = load_peer_cert(data_dir, &peer_pub)?;

    let prekey_store = PrekeyStore::load(data_dir);
    let peer_prekey = prekey_store
        .fetch(&peer_pub, now)?
        .ok_or_else(|| {
            "peer prekey missing — `ash prekey fetch` / OOB JSON into prekey store".to_string()
        })?;

    let trust = PairInitTrust {
        initiator_certificate: &local_cert,
        responder_certificate: &peer_cert,
        responder_prekey: &peer_prekey,
        initiator_revoked: false,
        responder_revoked: false,
    };

    let mut rng = OsRng;
    let mut eph = HybridKeypair::generate(&mut rng);
    let selected_x = if peer_prekey.one_time_prekey_id != 0 {
        peer_prekey
            .one_time_x25519_pub
            .ok_or("peer OTP missing")?
    } else {
        peer_prekey.x25519_pub
    };
    let pending = begin_hybrid_initiation(
        &mut rng,
        &eph.x25519_secret,
        &selected_x,
        &peer_prekey.mlkem768_ek,
    )
    .map_err(|e| format!("hybrid begin: {e}"))?;
    let ciphertext = pending.ciphertext().to_vec();

    let mut init_id = [0u8; 16];
    rng.fill_bytes(&mut init_id);
    let mut pairing_nonce = [0u8; 32];
    rng.fill_bytes(&mut pairing_nonce);
    let otp_pub = peer_prekey.one_time_x25519_pub.unwrap_or([0u8; 32]);

    let created = now;
    let expires = now.saturating_add(24 * 3600 * 1000);
    let mut init = PairInit {
        initiator_address: id.address(),
        responder_address: encode_address(&peer_pub),
        init_id,
        pairing_nonce,
        initiator_device_ed_pub: id.public_key_bytes(),
        responder_device_ed_pub: peer_cert.device_ed_pub,
        initiator_ephemeral_x25519_pub: eph.x25519_public,
        responder_signed_x25519_pub: peer_prekey.x25519_pub,
        responder_one_time_x25519_pub: otp_pub,
        initiator_device_cert_hash: device_certificate_hash(&local_cert)
            .map_err(|e| format!("{e:?}"))?,
        responder_device_cert_hash: device_certificate_hash(&peer_cert)
            .map_err(|e| format!("{e:?}"))?,
        responder_prekey_bundle_hash: prekey_bundle_hash(&peer_prekey)
            .map_err(|e| format!("{e:?}"))?,
        signed_prekey_id: peer_prekey.signed_prekey_id,
        one_time_prekey_id: peer_prekey.one_time_prekey_id,
        responder_mlkem768_ek: peer_prekey.mlkem768_ek.clone(),
        mlkem768_ciphertext: ciphertext,
        created_at_ms: created,
        expires_at_ms: expires,
        signature: [0u8; 64],
    };
    let signing = init_signing_bytes(&init).map_err(|e| format!("{e:?}"))?;
    init.signature = id.sign(&signing);
    eph.x25519_secret = [0u8; 32];

    let digest = transcript_hash(&init).map_err(|e| format!("{e:?}"))?;
    let (_ct, root) = pending.finalize(&digest);

    let mut store = IndexedSessionStore::open(data_dir).map_err(|e| e.redacted_display())?;
    let record_key = store
        .create_verified_pair_init_session(&init, &trust, now, LocalRole::Initiator, root)
        .map_err(|e| e.redacted_display())?;

    let init_wire = encode_init(&init).map_err(|e| format!("{e:?}"))?;
    let mut tag = [0u8; 16];
    rng.fill_bytes(&mut tag);
    let packed = wrap_oob_wire(
        &init_wire,
        PairInitOobKind::PairInit,
        id,
        tag,
        now,
        &mut rng,
    )?;

    let hint = if peer.trim().is_empty()
        || peer.eq_ignore_ascii_case("local-listen")
        || peer.eq_ignore_ascii_case("local")
    {
        "local-listen"
    } else {
        peer
    };
    ipc_enqueue(data_dir, &packed, hint)?;
    trace_delivery::trace_event(
        "ash/pair_init_lab.rs:run_pair_init_and_send",
        "TRACE_PAIR_INIT_ENQUEUED",
        "WAITING_FOR_PAIR_RESPONSE",
        Some(&hex::encode(&init_id[..4])),
        Some("lan_oob_rvn1_wrap"),
    );
    println!(
        "{C_GREEN}PairInit enqueued{C_RESET} init={}… → wait PairResponse (phone accept)",
        &hex::encode(init_id)[..8]
    );
    println!(
        "{C_DIM}sid{C_RESET} {}",
        hex::encode(session_id(&init).map_err(|e| format!("{e:?}"))?)
    );

    {
        let mut map = pending_inits().lock().map_err(|_| "pending lock")?;
        map.insert(
            init_id,
            PendingLabInit {
                init: init.clone(),
                record_key: record_key.clone(),
            },
        );
    }

    let response = wait_pair_response(data_dir, &init, peer, 90)?;
    store
        .confirm_verified_pair_response(&record_key, &init, &response, now_ms())
        .map_err(|e| e.redacted_display())?;
    trace_delivery::trace_event(
        "ash/pair_init_lab.rs:run_pair_init_and_send",
        "TRACE_PAIR_RESPONSE_CONFIRMED",
        "SESSION_CONFIRMED",
        Some(&hex::encode(&init_id[..4])),
        None,
    );
    println!("{C_GREEN}PairResponse confirmed{C_RESET} — sending indexed message");

    send_indexed_text(
        data_dir,
        id,
        &registry,
        &local_cert,
        &record_key,
        text,
        hint,
    )
}

fn wait_pair_response(
    data_dir: &Path,
    init: &PairInit,
    peer: &str,
    timeout_secs: u64,
) -> Result<PairResponse, String> {
    let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
    let dial = if peer.contains(':')
        && !peer.eq_ignore_ascii_case("local-listen")
        && !peer.eq_ignore_ascii_case("local")
    {
        Some(peer.to_string())
    } else {
        None
    };
    while std::time::Instant::now() < deadline {
        if let Some(ref addr) = dial {
            if let Ok(frames) = pull_frames(addr, 2) {
                for packed in frames {
                    if let PairInitOobClassify::PairResponse(wire) =
                        classify_packed_envelope(&packed)
                    {
                        if let Ok(response) = raven_core::pair_init::decode_response(&wire) {
                            if response.init_id == init.init_id {
                                return Ok(response);
                            }
                        }
                    }
                }
            }
        }
        let drop = data_dir.join("lab_pair_response.rvpr1");
        if drop.exists() {
            if let Ok(wire) = std::fs::read(&drop) {
                if let Ok(response) = raven_core::pair_init::decode_response(&wire) {
                    if response.init_id == init.init_id {
                        let _ = std::fs::remove_file(&drop);
                        return Ok(response);
                    }
                }
                if let PairInitOobClassify::PairResponse(wire) = classify_packed_envelope(&wire) {
                    if let Ok(response) = raven_core::pair_init::decode_response(&wire) {
                        if response.init_id == init.init_id {
                            let _ = std::fs::remove_file(&drop);
                            return Ok(response);
                        }
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(500));
        print!(".");
        let _ = std::io::stdout().flush();
    }
    println!();
    Err("WAITING_FOR_PAIR_RESPONSE:timeout".into())
}

fn pull_frames(host_port: &str, seconds: u64) -> Result<Vec<Vec<u8>>, String> {
    let mut stream =
        TcpStream::connect(host_port).map_err(|e| format!("dial {host_port}: {e}"))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(seconds)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    stream
        .write_all(b"RVNP")
        .map_err(|e| format!("pull hello: {e}"))?;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 65536];
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(seconds) {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                break;
            }
            Err(e) => return Err(format!("pull read: {e}")),
        }
    }
    let mut out = Vec::new();
    let mut offset = 0usize;
    while let Some((payload, next)) = deframe_prefix(&buf[offset..]) {
        out.push(payload);
        offset += next;
    }
    Ok(out)
}

fn send_indexed_text(
    data_dir: &Path,
    id: &Identity,
    registry: &DeviceRegistry,
    local_cert: &DeviceCertificate,
    record_key: &IndexedSessionRecordKey,
    text: &str,
    peer_hint: &str,
) -> Result<(), String> {
    let now = now_ms();
    let local_device = AuthorizedEndpointDevice::authorize(local_cert, id, registry, now)
        .map_err(|e| e.redacted_display())?;
    let mut store = IndexedSessionStore::open(data_dir).map_err(|e| e.redacted_display())?;
    let mut rng = OsRng;
    let mut queued: Option<([u8; 32], Vec<u8>)> = None;
    let outbound = store
        .send_message_envelope(
            record_key,
            text,
            &local_device,
            now,
            now.saturating_add(7 * 24 * 3600 * 1000),
            now,
            &mut rng,
            &mut |digest: &[u8; 32], bytes: &[u8]| {
                queued = Some((*digest, bytes.to_vec()));
                Ok(*digest)
            },
        )
        .map_err(|e| e.redacted_display())?;

    let (digest, packed) = queued.ok_or("send_message_envelope produced no queue bytes")?;
    if digest != outbound.object_digest {
        return Err("queue digest mismatch".into());
    }
    ipc_enqueue(data_dir, &packed, peer_hint)?;
    let mid = hex::encode(&outbound.message_id[..4]);
    trace_delivery::trace_event(
        "ash/pair_init_lab.rs:send_indexed_text",
        "TRACE_INDEXED_MESSAGE_ENQUEUED",
        "WAITING_FOR_ENDPOINT_ACK",
        Some(&mid),
        Some("send_message_envelope"),
    );
    println!(
        "{C_GREEN}indexed message enqueued{C_RESET} mid={mid}… peer={}",
        sanitize_terminal_text(peer_hint)
    );
    println!("{C_DIM}status{C_RESET} WAITING_FOR_ENDPOINT_ACK (not Sent until sealed ACK)");
    Ok(())
}

pub fn export_lab_device_cert(data_dir: &Path, id: &Identity) -> Result<(), String> {
    let (cert, _) = ensure_local_device_cert(data_dir, id)?;
    let path = data_dir.join("lab_device_cert.json");
    let json = serde_json::to_string_pretty(&cert).map_err(|e| e.to_string())?;
    std::fs::write(&path, json).map_err(|e| e.to_string())?;
    println!(
        "{C_BOLD}lab device cert{C_RESET} → {} (give peer; map key = your pub_hex)",
        path.display()
    );
    println!(
        "{C_DIM}peer_device_certs.json entry key{C_RESET} {}",
        hex::encode(id.public_key_bytes())
    );
    Ok(())
}

pub fn import_peer_device_cert(
    data_dir: &Path,
    peer_pub_hex: &str,
    cert_json_path: &Path,
) -> Result<(), String> {
    let peer = parse_pub_hex(peer_pub_hex)?;
    let raw = std::fs::read_to_string(cert_json_path).map_err(|e| e.to_string())?;
    let cert: DeviceCertificate =
        serde_json::from_str(&raw).map_err(|e| format!("cert json: {e}"))?;
    if cert.user_ed_pub != peer && cert.device_ed_pub != peer {
        return Err("cert does not match peer_pub_hex".into());
    }
    cache_peer_cert(data_dir, &peer, &cert)?;
    println!("{C_GREEN}peer cert cached{C_RESET} for {peer_pub_hex}");
    Ok(())
}

#[allow(dead_code)]
pub fn ingest_pair_response_packed(data_dir: &Path, packed: &[u8]) -> Result<(), String> {
    let PairInitOobClassify::PairResponse(wire) = classify_packed_envelope(packed) else {
        return Err("not PairResponse OOB".into());
    };
    let response =
        raven_core::pair_init::decode_response(&wire).map_err(|e| format!("{e:?}"))?;
    let mut map = pending_inits().lock().map_err(|_| "pending lock")?;
    let Some(pending) = map.remove(&response.init_id) else {
        return Err("no pending PairInit for this response".into());
    };
    let mut store = IndexedSessionStore::open(data_dir).map_err(|e| e.redacted_display())?;
    store
        .confirm_verified_pair_response(&pending.record_key, &pending.init, &response, now_ms())
        .map_err(|e| e.redacted_display())?;
    let path = data_dir.join("lab_pair_response.rvpr1");
    std::fs::write(&path, wire).map_err(|e| e.to_string())?;
    Ok(())
}

#[allow(dead_code)]
fn _path_marker() -> PathBuf {
    PathBuf::from(".")
}
