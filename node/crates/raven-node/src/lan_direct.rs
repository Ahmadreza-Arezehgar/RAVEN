//! Direct LAN TCP: Noise XX + RLB1 + inbound PairInit/message/ACK dispatch.
//!
//! This path does not use `bridge_run` fanout.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use raven_core::identity::Identity;
use raven_core::lan_dispatch::{
    cache_peer_bundle, dispatch_frame, encode_local_offer, lan_peer_blocked, parse_peer_offer,
    remember_ephemeral_peer, rlb1_matches_noise_identity,
};
use raven_core::lan_noise::{
    build_initiator, build_responder, derive_noise_static, encode_bind, get_remote_static,
    handshake_read, handshake_write, into_transport, noise_static_public, transport_decrypt,
    transport_encrypt, verify_bind, NoiseTransport, MAX_TRANSPORT_PLAINTEXT,
};
use raven_core::load_identity_required;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};

const MAX_FRAME: usize = 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(30);
const REPLY_IDLE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy)]
struct InboundLimits {
    max_conns: usize,
    max_per_ip: usize,
    max_frames: u32,
    lifetime: Duration,
}

const PRODUCTION_LIMITS: InboundLimits = InboundLimits {
    max_conns: 32,
    max_per_ip: 4,
    max_frames: 64,
    lifetime: Duration::from_secs(120),
};

fn try_admit_connection(
    slots: &Arc<Semaphore>,
    per_ip: &mut HashMap<IpAddr, usize>,
    ip: IpAddr,
    max_per_ip: usize,
) -> Option<tokio::sync::OwnedSemaphorePermit> {
    let permit = Arc::clone(slots).try_acquire_owned().ok()?;
    let n = per_ip.entry(ip).or_insert(0);
    if *n >= max_per_ip {
        return None;
    }
    *n += 1;
    Some(permit)
}

fn release_ip_slot(per_ip: &mut HashMap<IpAddr, usize>, ip: IpAddr) {
    if let Some(n) = per_ip.get_mut(&ip) {
        *n = n.saturating_sub(1);
        if *n == 0 {
            per_ip.remove(&ip);
        }
    }
}

fn frame_budget_allows(frames_seen: &mut u32, max_frames: u32) -> bool {
    *frames_seen = frames_seen.saturating_add(1);
    *frames_seen <= max_frames
}

static LISTENER_UP: AtomicBool = AtomicBool::new(false);

pub fn listener_is_up() -> bool {
    LISTENER_UP.load(Ordering::Relaxed)
}

struct ListenerGuard;
impl Drop for ListenerGuard {
    fn drop(&mut self) {
        LISTENER_UP.store(false, Ordering::Relaxed);
    }
}

fn parse_pub_hex(s: &str) -> Result<[u8; 32], String> {
    let h = s.trim().to_lowercase();
    if h.len() != 32 * 2 {
        return Err("expected_pub_hex must be 64 hex chars".into());
    }
    let v = hex::decode(&h).map_err(|_| "expected_pub_hex invalid hex".to_string())?;
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

pub fn looks_like_lan_dial(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() || t.contains(' ') || t.starts_with("rvn1") {
        return false;
    }
    let Some((host, port)) = t.rsplit_once(':') else {
        return false;
    };
    !host.is_empty() && port.parse::<u16>().ok().is_some_and(|p| p != 0)
}

async fn write_raw(stream: &mut TcpStream, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > MAX_FRAME {
        return Err("lan frame too large".into());
    }
    let write = async {
        stream
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await
            .map_err(|e| e.to_string())?;
        stream.write_all(bytes).await.map_err(|e| e.to_string())?;
        stream.flush().await.map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    };
    tokio::time::timeout(IO_TIMEOUT, write)
        .await
        .map_err(|_| "lan write timeout".to_string())?
}

async fn read_raw(stream: &mut TcpStream) -> Result<Vec<u8>, String> {
    let read = async {
        let mut len_buf = [0u8; 4];
        stream
            .read_exact(&mut len_buf)
            .await
            .map_err(|e| e.to_string())?;
        let n = u32::from_be_bytes(len_buf) as usize;
        if n == 0 || n > MAX_FRAME {
            return Err("lan frame length".into());
        }
        let mut buf = vec![0u8; n];
        stream
            .read_exact(&mut buf)
            .await
            .map_err(|e| e.to_string())?;
        Ok(buf)
    };
    tokio::time::timeout(IO_TIMEOUT, read)
        .await
        .map_err(|_| "lan read timeout".to_string())?
}

async fn write_cipher(
    stream: &mut TcpStream,
    transport: &mut NoiseTransport,
    plain: &[u8],
) -> Result<(), String> {
    if plain.len() > MAX_TRANSPORT_PLAINTEXT {
        return Err("lan payload exceeds Noise transport limit".into());
    }
    let ct = transport_encrypt(transport, plain).map_err(|e| e.to_string())?;
    write_raw(stream, &ct).await
}

async fn read_cipher(
    stream: &mut TcpStream,
    transport: &mut NoiseTransport,
) -> Result<Vec<u8>, String> {
    let ct = read_raw(stream).await?;
    transport_decrypt(transport, &ct).map_err(|e| e.to_string())
}

async fn initiator_session(
    stream: &mut TcpStream,
    identity: &Identity,
    expected: &[u8; 32],
) -> Result<NoiseTransport, String> {
    let secret = derive_noise_static(identity).map_err(|e| e.to_string())?;
    let local_pub = noise_static_public(&secret);
    let mut hs = build_initiator(&secret).map_err(|e| e.to_string())?;
    let m1 = handshake_write(&mut hs, &[]).map_err(|e| e.to_string())?;
    write_raw(stream, &m1).await?;
    let m2 = read_raw(stream).await?;
    handshake_read(&mut hs, &m2).map_err(|e| e.to_string())?;
    let m3 = handshake_write(&mut hs, &[]).map_err(|e| e.to_string())?;
    write_raw(stream, &m3).await?;
    let remote_static = get_remote_static(&hs).map_err(|e| e.to_string())?;
    let mut t = into_transport(hs).map_err(|e| e.to_string())?;
    write_cipher(stream, &mut t, &encode_bind(identity, &local_pub)).await?;
    let bind = read_cipher(stream, &mut t).await?;
    verify_bind(&bind, &remote_static, Some(expected)).map_err(|e| e.to_string())?;
    Ok(t)
}

async fn responder_session(
    stream: &mut TcpStream,
    identity: &Identity,
) -> Result<([u8; 32], NoiseTransport), String> {
    let secret = derive_noise_static(identity).map_err(|e| e.to_string())?;
    let local_pub = noise_static_public(&secret);
    let mut hs = build_responder(&secret).map_err(|e| e.to_string())?;
    let m1 = read_raw(stream).await?;
    handshake_read(&mut hs, &m1).map_err(|e| e.to_string())?;
    let m2 = handshake_write(&mut hs, &[]).map_err(|e| e.to_string())?;
    write_raw(stream, &m2).await?;
    let m3 = read_raw(stream).await?;
    handshake_read(&mut hs, &m3).map_err(|e| e.to_string())?;
    let remote_static = get_remote_static(&hs).map_err(|e| e.to_string())?;
    let mut t = into_transport(hs).map_err(|e| e.to_string())?;
    let bind = read_cipher(stream, &mut t).await?;
    let remote_ed = verify_bind(&bind, &remote_static, None).map_err(|e| e.to_string())?;
    write_cipher(stream, &mut t, &encode_bind(identity, &local_pub)).await?;
    Ok((remote_ed, t))
}

async fn handle_inbound(
    data_dir: PathBuf,
    mut stream: TcpStream,
    limits: InboundLimits,
) -> Result<(), String> {
    let started = std::time::Instant::now();
    let identity = load_identity_required(&data_dir).map_err(|e| e.to_string())?;
    let (remote_ed, mut transport) = responder_session(&mut stream, &identity).await?;
    let peer_offer = read_cipher(&mut stream, &mut transport).await?;
    let peer = parse_peer_offer(&peer_offer)?;
    if !rlb1_matches_noise_identity(&peer, &remote_ed) {
        return Err("rlb1/noise identity mismatch".into());
    }
    if lan_peer_blocked(&data_dir, &peer, &remote_ed)? {
        return Err("blocked peer".into());
    }
    // Unknown inbound peers stay ephemeral until PairInit confirms trust.
    remember_ephemeral_peer(&data_dir, &peer)?;
    let local = encode_local_offer(&data_dir, &identity)?;
    write_cipher(&mut stream, &mut transport, &local).await?;

    let mut frames_seen = 0u32;
    loop {
        if started.elapsed() > limits.lifetime {
            return Err("lan connection lifetime exceeded".into());
        }
        let frame = match tokio::time::timeout(IO_TIMEOUT, read_cipher(&mut stream, &mut transport))
            .await
        {
            Ok(Ok(f)) => f,
            Ok(Err(e)) => {
                eprintln!("lan_direct inbound read: {e}");
                break;
            }
            Err(_) => break,
        };
        if !frame_budget_allows(&mut frames_seen, limits.max_frames) {
            return Err("lan frame budget exceeded".into());
        }
        if lan_peer_blocked(&data_dir, &peer, &remote_ed)? {
            return Err("blocked peer".into());
        }
        let dd = data_dir.clone();
        let peer_c = peer.clone();
        let frame_c = frame.clone();
        let noise_ed = remote_ed;
        let replies = tokio::task::spawn_blocking(move || {
            let identity = load_identity_required(&dd).map_err(|e| e.to_string())?;
            dispatch_frame(&dd, &identity, &peer_c, &noise_ed, &frame_c)
        })
        .await
        .map_err(|e| format!("dispatch join: {e}"))?
        .map_err(|e| {
            eprintln!("lan_direct dispatch: {e}");
            e
        })?;
        for reply in replies {
            write_cipher(&mut stream, &mut transport, &reply).await?;
        }
    }
    Ok(())
}

fn preflight_lan_ready(data_dir: &Path) -> Result<(), String> {
    let identity = load_identity_required(data_dir).map_err(|e| e.to_string())?;
    raven_core::ensure_local_prekey(data_dir, &identity)?;
    let _ = raven_core::IndexedSessionStore::open(data_dir).map_err(|e| e.redacted_display())?;
    let _ = raven_core::PrekeyLifecycleActor::open(data_dir).map_err(|e| e.to_string())?;
    raven_core::maintain_lan_durable_state(data_dir)?;
    Ok(())
}

/// Listen on `lan_listen` and dispatch inbound LAN-direct sessions.
pub async fn run_listener(data_dir: PathBuf, lan_listen: String) -> Result<(), String> {
    run_listener_with_limits(data_dir, lan_listen, PRODUCTION_LIMITS).await
}

async fn run_listener_with_limits(
    data_dir: PathBuf,
    lan_listen: String,
    limits: InboundLimits,
) -> Result<(), String> {
    preflight_lan_ready(&data_dir)?;
    let listener = TcpListener::bind(&lan_listen)
        .await
        .map_err(|e| format!("lan_direct bind {lan_listen}: {e}"))?;
    let local = listener.local_addr().map_err(|e| e.to_string())?;
    eprintln!("raven-node lan_direct: listen {local}");
    LISTENER_UP.store(true, Ordering::Relaxed);
    let _up = ListenerGuard;
    let slots = Arc::new(Semaphore::new(limits.max_conns));
    let per_ip = Arc::new(Mutex::new(HashMap::<IpAddr, usize>::new()));
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let ip = addr.ip();
                let permit = {
                    let mut map = per_ip.lock().await;
                    try_admit_connection(&slots, &mut map, ip, limits.max_per_ip)
                };
                let Some(permit) = permit else {
                    eprintln!("lan_direct: connection cap");
                    continue;
                };
                let dd = data_dir.clone();
                let per_ip_c = per_ip.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let result =
                        tokio::time::timeout(limits.lifetime, handle_inbound(dd, stream, limits))
                            .await;
                    {
                        let mut map = per_ip_c.lock().await;
                        release_ip_slot(&mut map, ip);
                    }
                    match result {
                        Ok(Err(e)) => eprintln!("lan_direct inbound: {e}"),
                        Err(_) => eprintln!("lan_direct inbound: connection lifetime exceeded"),
                        Ok(Ok(())) => {}
                    }
                });
            }
            Err(e) => return Err(format!("lan_direct accept: {e}")),
        }
    }
}

/// Dial `lan_dial`, complete Noise+RLB1, send `frames`, collect replies.
pub async fn dial(
    data_dir: &Path,
    lan_dial: &str,
    expected_pub_hex: &str,
    frames: &[Vec<u8>],
) -> Result<Vec<Vec<u8>>, String> {
    if !looks_like_lan_dial(lan_dial) {
        return Err("lan_dial must be host:port (e.g. 192.168.1.20:7420)".into());
    }
    let expected = parse_pub_hex(expected_pub_hex)?;
    let addr: SocketAddr = lan_dial
        .parse()
        .map_err(|e| format!("lan_dial parse: {e}"))?;
    let identity = load_identity_required(data_dir).map_err(|e| e.to_string())?;
    let connect = TcpStream::connect(addr);
    let mut stream = tokio::time::timeout(IO_TIMEOUT, connect)
        .await
        .map_err(|_| "lan dial timeout".to_string())?
        .map_err(|e| format!("lan connect: {e}"))?;

    let mut transport = initiator_session(&mut stream, &identity, &expected).await?;
    let local = encode_local_offer(data_dir, &identity)?;
    write_cipher(&mut stream, &mut transport, &local).await?;
    let peer_offer = read_cipher(&mut stream, &mut transport).await?;
    let peer = parse_peer_offer(&peer_offer)?;
    if peer.cert.device_ed_pub != expected && peer.cert.user_ed_pub != expected {
        return Err("rlb1 offer identity mismatch".into());
    }
    if lan_peer_blocked(data_dir, &peer, &expected)? {
        return Err("blocked peer".into());
    }
    cache_peer_bundle(data_dir, &peer)?;

    let mut replies = vec![peer_offer];
    for frame in frames {
        write_cipher(&mut stream, &mut transport, frame).await?;
    }
    if frames.is_empty() {
        return Ok(replies);
    }
    // First reply may hit Keychain / session persist; do not use the short idle.
    match tokio::time::timeout(IO_TIMEOUT, read_cipher(&mut stream, &mut transport)).await {
        Ok(Ok(frame)) => replies.push(frame),
        _ => return Ok(replies),
    }
    while let Ok(Ok(frame)) =
        tokio::time::timeout(REPLY_IDLE, read_cipher(&mut stream, &mut transport)).await
    {
        replies.push(frame);
    }
    Ok(replies)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn preflight_fails_without_identity() {
        let dir = tempfile::tempdir().unwrap();
        let err = preflight_lan_ready(dir.path()).unwrap_err();
        assert!(!err.is_empty());
        assert!(!listener_is_up());
    }

    #[test]
    fn inbound_caps_are_bounded() {
        const {
            assert!(PRODUCTION_LIMITS.max_conns >= PRODUCTION_LIMITS.max_per_ip);
            assert!(PRODUCTION_LIMITS.max_frames > 0);
        }
        assert!(PRODUCTION_LIMITS.lifetime.as_secs() >= 30);
    }

    #[test]
    fn admission_enforces_global_and_per_ip_caps() {
        let slots = Arc::new(Semaphore::new(2));
        let mut per_ip = HashMap::new();
        let ip_a = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
        let ip_b = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2));
        let p1 = try_admit_connection(&slots, &mut per_ip, ip_a, 1).expect("first");
        assert!(try_admit_connection(&slots, &mut per_ip, ip_a, 1).is_none());
        let p2 = try_admit_connection(&slots, &mut per_ip, ip_b, 1).expect("second ip");
        assert!(try_admit_connection(&slots, &mut per_ip, ip_b, 1).is_none());
        drop(p1);
        release_ip_slot(&mut per_ip, ip_a);
        let _p3 = try_admit_connection(&slots, &mut per_ip, ip_a, 1).expect("reuse after release");
        drop(p2);
    }

    #[test]
    fn frame_budget_rejects_after_max() {
        let mut seen = 0u32;
        for _ in 0..3 {
            assert!(frame_budget_allows(&mut seen, 3));
        }
        assert!(!frame_budget_allows(&mut seen, 3));
        assert_eq!(seen, 4);
    }
}
