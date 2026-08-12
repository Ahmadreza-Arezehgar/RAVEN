//! Raven local node — TCP framed RavenEnvelopeV1, persistent queue, ACK/dedup.
//! Bridge V1: opaque cross-transport forward (see `bridge_run`).
//! Frame: u32 BE length || envelope bytes. Never logs private keys or plaintext.

mod bridge_run;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use rand::RngCore;
use raven_core::ack::{Ack, STATUS_DELIVERED};
use raven_core::envelope::{Envelope, EnvType};
use raven_core::forward_queue::ForwardQueue;
use raven_core::identity::Identity;
use raven_core::node_policy::{load_policy, BridgeStatusSnapshot};
use raven_core::queue::{DeliveryState, OutgoingQueue, QueueItem};
use raven_core::routing_tag;
use raven_core::seal::{
    classify_sealed_body, derive_pairwise_key, parse_rvna1_header, rvna1_wire_plausible,
    seal_message, unseal_message, SealClass, ATSAM_PROTO_V2, SEAL_MAGIC_RVNA1, STUB_SUITE,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use zeroize::Zeroize;

#[derive(Parser, Debug)]
#[command(name = "raven-node", about = "RAVEN serverless local node")]
struct Cli {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Create a new identity in --data-dir (prints ADDRESS only, never the seed).
    Init {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
    },
    /// Print public address for this data dir.
    Address {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
    },
    /// Run listener; optionally send one message then wait for ACK.
    Run {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
        #[arg(long, default_value = "127.0.0.1:0")]
        listen: String,
        /// Optional peer to dial (host:port).
        #[arg(long)]
        peer: Option<String>,
        /// Peer Ed25519 public key hex (32 bytes) for seal + verify.
        #[arg(long)]
        peer_pub_hex: Option<String>,
        /// Text to send (encrypted). Omit to listen-only.
        #[arg(long)]
        send: Option<String>,
        /// Body mode for --send: `interim` (default, decryptable stub) or
        /// `opaque-atsam` (RVNA1 proto=0x02 placeholder — node ACKs without decrypt).
        #[arg(long, default_value = "interim")]
        body_mode: String,
        /// Write bound listen address to this file (for demo scripts).
        #[arg(long)]
        write_addr: Option<PathBuf>,
        /// Write public key hex to this file (safe — public only).
        #[arg(long)]
        write_pub: Option<PathBuf>,
        /// Exit after successful send+ACK or after receiving N messages.
        #[arg(long, default_value_t = 0)]
        exit_after_recv: u32,
        #[arg(long, default_value_t = false)]
        exit_after_ack: bool,
        /// How long to run max (seconds).
        #[arg(long, default_value_t = 30)]
        timeout_secs: u64,
        /// Seal plaintext to this pub (A→C via bridge). Defaults to peer_pub_hex.
        #[arg(long)]
        seal_to_pub_hex: Option<String>,
        /// Verify inbound Message signatures with this pub (C verifies A).
        #[arg(long)]
        origin_pub_hex: Option<String>,
        /// Verify ACK signatures with this pub (A verifies C). Defaults to peer_pub_hex.
        #[arg(long)]
        ack_pub_hex: Option<String>,
    },
    /// Bridge daemon: LAN + mock-BLE opaque forward (survives ash exit).
    Bridge {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
        #[arg(long, default_value = "127.0.0.1:0")]
        lan_listen: String,
        #[arg(long, default_value = "127.0.0.1:0")]
        ble_listen: String,
        #[arg(long)]
        write_lan_addr: Option<PathBuf>,
        #[arg(long)]
        write_ble_addr: Option<PathBuf>,
        #[arg(long)]
        write_status: Option<PathBuf>,
        /// 0 = run until killed (normal daemon).
        #[arg(long, default_value_t = 0)]
        timeout_secs: u64,
    },
    /// Print bridge/policy status (safe fields only).
    Status {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
    },
    /// Replay pending queue items to peer (crash recovery).
    Flush {
        #[arg(long, default_value = "./raven-data")]
        data_dir: PathBuf,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_pub_hex: String,
        #[arg(long, default_value_t = 15)]
        timeout_secs: u64,
    },
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn identity_path(data_dir: &Path) -> PathBuf {
    data_dir.join("identity.seed")
}

fn queue_path(data_dir: &Path) -> PathBuf {
    data_dir.join("queue.sqlite")
}

fn load_or_err(data_dir: &Path) -> Result<Identity, String> {
    let path = identity_path(data_dir);
    let bytes = std::fs::read(&path).map_err(|e| format!("read identity: {e}"))?;
    if bytes.len() != 32 {
        return Err("corrupt identity seed length".into());
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&bytes);
    let id = Identity::from_seed(&seed);
    seed.zeroize();
    Ok(id)
}

fn init_identity(data_dir: &Path) -> Result<Identity, String> {
    std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
    let path = identity_path(data_dir);
    if path.exists() {
        return load_or_err(data_dir);
    }
    let id = Identity::generate();
    let seed = id.seed_bytes();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| e.to_string())?;
        use std::io::Write;
        f.write_all(&seed).map_err(|e| e.to_string())?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&path, &seed).map_err(|e| e.to_string())?;
    }
    let mut s = seed;
    s.zeroize();
    Ok(id)
}

async fn write_frame(stream: &mut TcpStream, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > 24 * 1024 * 1024 {
        return Err("frame too large".into());
    }
    let len = (bytes.len() as u32).to_be_bytes();
    stream.write_all(&len).await.map_err(|e| e.to_string())?;
    stream.write_all(bytes).await.map_err(|e| e.to_string())?;
    stream.flush().await.map_err(|e| e.to_string())?;
    Ok(())
}

async fn read_frame(stream: &mut TcpStream) -> Result<Vec<u8>, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| e.to_string())?;
    let len = u32::from_be_bytes(len_buf) as usize;
    // Incremental: reject absurd sizes before alloc (DoS note from envelope spec).
    if len == 0 || len > 1 * 1024 * 1024 {
        return Err("invalid frame length".into());
    }
    let mut buf = vec![0u8; len];
    stream
        .read_exact(&mut buf)
        .await
        .map_err(|e| e.to_string())?;
    Ok(buf)
}

fn parse_pub_hex(s: &str) -> Result<[u8; 32], String> {
    let v = hex::decode(s.trim()).map_err(|e| e.to_string())?;
    if v.len() != 32 {
        return Err("peer_pub_hex must be 32 bytes".into());
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

/// Synthetic opaque ATSAM v2-shaped body for LAN smoke (not real ciphertext).
/// iOS may send real ATSAM frames; raven-node treats both as opaque.
fn opaque_atsam_placeholder(plaintext_len_hint: usize) -> Vec<u8> {
    let mut body = Vec::with_capacity(8 + 2 + 4 + 12 + 16 + plaintext_len_hint.min(32));
    body.extend_from_slice(&SEAL_MAGIC_RVNA1);
    body.push(ATSAM_PROTO_V2);
    body.push(STUB_SUITE);
    body.extend_from_slice(&0u32.to_be_bytes()); // index
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    body.extend_from_slice(&nonce);
    // Fake ct+tag — length only matters for DELIVERED opaque metrics.
    let mut ct = vec![0u8; 16 + plaintext_len_hint.min(64)];
    rand::thread_rng().fill_bytes(&mut ct);
    body.extend_from_slice(&ct);
    body
}

fn build_message_envelope(
    identity: &Identity,
    peer_pub: &[u8; 32],
    plaintext: &[u8],
    message_id: [u8; 16],
    body_mode: &str,
) -> Result<Envelope, String> {
    let my_pub = identity.public_key_bytes();
    let my_addr = identity.address();
    let peer_addr = raven_core::encode_address(peer_pub);
    let sealed = match body_mode {
        "interim" | "" => {
            let key = derive_pairwise_key(&my_pub, peer_pub);
            seal_message(&key, plaintext, &my_addr, &peer_addr, &message_id)?
        }
        "opaque-atsam" => opaque_atsam_placeholder(plaintext.len()),
        other => return Err(format!("unknown body_mode={other} (use interim|opaque-atsam)")),
    };
    let k_route = derive_pairwise_key(&my_pub, peer_pub); // demo: reuse pairwise as K_route material
    let tag = routing_tag::derive(&k_route, now_ms() / 1000, 0);
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    let flags = if body_mode == "opaque-atsam" { 1u16 } else { 0 }; // hybridPQ hint bit0
    let mut env = Envelope {
        env_type: EnvType::Message as u8,
        flags,
        message_id,
        routing_tag: tag,
        dest_device_hint: 0,
        created_at: now_ms(),
        expires_at: now_ms() + 86_400_000,
        hop_limit: 8,
        replication_budget: 3,
        anti_replay_nonce: nonce,
        ratchet_header_ciphertext: vec![],
        message_ciphertext: sealed,
        sender_authentication: vec![],
    };
    env.sign_with(identity);
    Ok(env)
}

fn build_ack_envelope(
    identity: &Identity,
    acked_message_id: [u8; 16],
    peer_pub: &[u8; 32],
) -> Envelope {
    let mut ack_nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut ack_nonce);
    let ack = Ack {
        acked_message_id,
        status: STATUS_DELIVERED,
        ack_nonce,
        created_at: now_ms(),
    };
    let sig = ack.sign(identity);
    let body = {
        let mut b = Vec::new();
        b.extend_from_slice(&ack.acked_message_id);
        b.push(ack.status);
        b.extend_from_slice(&ack.ack_nonce);
        b.extend_from_slice(&ack.created_at.to_be_bytes());
        b.extend_from_slice(&sig);
        b
    };
    let mut mid = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut mid);
    let k_route = derive_pairwise_key(&identity.public_key_bytes(), peer_pub);
    let tag = routing_tag::derive(&k_route, now_ms() / 1000, 1);
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    let mut env = Envelope {
        env_type: EnvType::Ack as u8,
        flags: 0,
        message_id: mid,
        routing_tag: tag,
        dest_device_hint: 0,
        created_at: now_ms(),
        expires_at: now_ms() + 86_400_000,
        hop_limit: 8,
        replication_budget: 1,
        anti_replay_nonce: nonce,
        ratchet_header_ciphertext: vec![],
        message_ciphertext: body,
        sender_authentication: vec![],
    };
    env.sign_with(identity);
    env
}

struct NodeState {
    identity: Identity,
    queue: OutgoingQueue,
    /// Default peer pub (legacy two-node).
    peer_pub: Option<[u8; 32]>,
    /// Verify Message env signatures (origin A when C is recipient).
    origin_pub: Option<[u8; 32]>,
    /// Verify ACK signatures (C when A is sender).
    ack_pub: Option<[u8; 32]>,
    recv_count: u32,
    got_ack: bool,
}

impl NodeState {
    fn msg_verify_pub(&self) -> Option<[u8; 32]> {
        self.origin_pub.or(self.peer_pub)
    }

    fn ack_verify_pub(&self) -> Option<[u8; 32]> {
        self.ack_pub.or(self.peer_pub)
    }

    fn handle_inbound(&mut self, raw: &[u8]) -> Result<Option<Vec<u8>>, String> {
        let env = Envelope::unpack(raw).ok_or_else(|| "malformed envelope".to_string())?;
        if now_ms() > env.expires_at {
            return Ok(None);
        }
        let dup = self
            .queue
            .dedup_check_and_insert(&env.message_id, now_ms())
            .map_err(|e| e.to_string())?;
        if dup {
            eprintln!("raven-node: dedup drop message_id={}", hex::encode(env.message_id));
            return Ok(None);
        }

        match env.env_type {
            x if x == EnvType::Message as u8 => {
                let peer_pub = self
                    .msg_verify_pub()
                    .ok_or_else(|| "origin/peer pub required to verify".to_string())?;
                if !env.verify(&peer_pub) {
                    return Err("envelope auth failed".into());
                }
                let my_addr = self.identity.address();
                let peer_addr = raven_core::encode_address(&peer_pub);
                match classify_sealed_body(&env.message_ciphertext) {
                    SealClass::InterimStub => {
                        let key =
                            derive_pairwise_key(&self.identity.public_key_bytes(), &peer_pub);
                        let pt = unseal_message(
                            &key,
                            &env.message_ciphertext,
                            &peer_addr,
                            &my_addr,
                            &env.message_id,
                        )?;
                        eprintln!(
                            "raven-node: DELIVERED bytes={} from={}",
                            pt.len(),
                            peer_addr
                        );
                    }
                    SealClass::OpaqueAtsam { proto } => {
                        if !rvna1_wire_plausible(&env.message_ciphertext) {
                            return Err(format!(
                                "opaque ATSAM proto={proto:#x} truncated or bad suite"
                            ));
                        }
                        let hdr = parse_rvna1_header(&env.message_ciphertext);
                        let idx = hdr.and_then(|h| h.index);
                        eprintln!(
                            "raven-node: DELIVERED opaque_atsam proto={:#x}{} bytes={} from={}",
                            proto,
                            idx.map(|i| format!(" index={i}")).unwrap_or_default(),
                            env.message_ciphertext.len(),
                            peer_addr
                        );
                    }
                    SealClass::Other => {
                        return Err("unsupported message_ciphertext seal class".into());
                    }
                }
                self.recv_count += 1;
                let ack = build_ack_envelope(&self.identity, env.message_id, &peer_pub);
                Ok(Some(ack.pack()))
            }
            x if x == EnvType::Ack as u8 => {
                let peer_pub = self
                    .ack_verify_pub()
                    .ok_or_else(|| "ack/peer pub required to verify".to_string())?;
                if !env.verify(&peer_pub) {
                    return Err("ack envelope auth failed".into());
                }
                if env.message_ciphertext.len() < 16 + 1 + 12 + 8 + 64 {
                    return Err("short ack body".into());
                }
                let mut acked = [0u8; 16];
                acked.copy_from_slice(&env.message_ciphertext[0..16]);
                let status = env.message_ciphertext[16];
                let mut ack_nonce = [0u8; 12];
                ack_nonce.copy_from_slice(&env.message_ciphertext[17..29]);
                let created_at = u64::from_be_bytes(
                    env.message_ciphertext[29..37]
                        .try_into()
                        .map_err(|_| "ack ts")?,
                );
                let mut sig = [0u8; 64];
                sig.copy_from_slice(&env.message_ciphertext[37..101]);
                let ack = Ack {
                    acked_message_id: acked,
                    status,
                    ack_nonce,
                    created_at,
                };
                if !ack.verify(&sig, &peer_pub) {
                    return Err("ack signature failed".into());
                }
                if status == STATUS_DELIVERED {
                    self.queue
                        .mark_state(&acked, DeliveryState::Delivered)
                        .map_err(|e| e.to_string())?;
                    self.got_ack = true;
                    eprintln!("raven-node: ACK delivered for {}", hex::encode(acked));
                }
                Ok(None)
            }
            _ => Ok(None),
        }
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    state: Arc<Mutex<NodeState>>,
) -> Result<(), String> {
    loop {
        let frame = match read_frame(&mut stream).await {
            Ok(f) => f,
            Err(e) => {
                // Peer closed or truncated — not a panic.
                eprintln!("raven-node: connection end ({e})");
                break;
            }
        };
        let reply = {
            let mut st = state.lock().await;
            match st.handle_inbound(&frame) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("raven-node: drop inbound ({e})");
                    None
                }
            }
        };
        if let Some(ack_bytes) = reply {
            write_frame(&mut stream, &ack_bytes).await?;
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Commands::Init { data_dir } => match init_identity(&data_dir) {
            Ok(id) => {
                println!("address={}", id.address());
                println!("pub_hex={}", hex::encode(id.public_key_bytes()));
                // NEVER print seed.
            }
            Err(e) => {
                eprintln!("init failed: {e}");
                std::process::exit(1);
            }
        },
        Commands::Address { data_dir } => match load_or_err(&data_dir) {
            Ok(id) => {
                println!("address={}", id.address());
                println!("pub_hex={}", hex::encode(id.public_key_bytes()));
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        },
        Commands::Run {
            data_dir,
            listen,
            peer,
            peer_pub_hex,
            send,
            body_mode,
            write_addr,
            write_pub,
            exit_after_recv,
            exit_after_ack,
            timeout_secs,
            seal_to_pub_hex,
            origin_pub_hex,
            ack_pub_hex,
        } => {
            let identity = init_identity(&data_dir).unwrap_or_else(|e| {
                eprintln!("{e}");
                std::process::exit(1);
            });
            if let Some(path) = write_pub {
                let _ = std::fs::write(path, hex::encode(identity.public_key_bytes()));
            }
            let queue = OutgoingQueue::open(&queue_path(&data_dir)).unwrap_or_else(|e| {
                eprintln!("queue: {e}");
                std::process::exit(1);
            });
            let peer_pub = peer_pub_hex.as_ref().and_then(|s| parse_pub_hex(s).ok());
            let origin_pub = origin_pub_hex.as_ref().and_then(|s| parse_pub_hex(s).ok());
            let ack_pub = ack_pub_hex.as_ref().and_then(|s| parse_pub_hex(s).ok());
            let seal_to = seal_to_pub_hex
                .as_ref()
                .and_then(|s| parse_pub_hex(s).ok())
                .or(peer_pub);
            let state = Arc::new(Mutex::new(NodeState {
                identity,
                queue,
                peer_pub,
                origin_pub,
                ack_pub,
                recv_count: 0,
                got_ack: false,
            }));

            let listener = TcpListener::bind(&listen).await.unwrap_or_else(|e| {
                eprintln!("bind: {e}");
                std::process::exit(1);
            });
            let local = listener.local_addr().unwrap();
            eprintln!("raven-node: listen {local}");
            if let Some(path) = write_addr {
                let _ = std::fs::write(path, local.to_string());
            }

            let state_accept = state.clone();
            tokio::spawn(async move {
                loop {
                    match listener.accept().await {
                        Ok((stream, addr)) => {
                            eprintln!("raven-node: accept {addr}");
                            let st = state_accept.clone();
                            tokio::spawn(async move {
                                let _ = handle_connection(stream, st).await;
                            });
                        }
                        Err(e) => {
                            eprintln!("accept err: {e}");
                            break;
                        }
                    }
                }
            });

            if let (Some(peer_s), Some(text), Some(pp)) = (peer.as_ref(), send.as_ref(), seal_to)
            {
                let mut mid = [0u8; 16];
                rand::thread_rng().fill_bytes(&mut mid);
                let env = {
                    let st = state.lock().await;
                    build_message_envelope(&st.identity, &pp, text.as_bytes(), mid, &body_mode)
                        .unwrap_or_else(|e| {
                            eprintln!("{e}");
                            std::process::exit(1);
                        })
                };
                let packed = env.pack();
                {
                    let id = raven_core::EnvelopeIdentity::from_envelope(&env);
                    eprintln!(
                        "raven-node: ENVELOPE_FP mid={} body_sha256={}",
                        hex::encode(id.message_id),
                        hex::encode(id.body_sha256)
                    );
                }
                {
                    let st = state.lock().await;
                    st.queue
                        .enqueue(&QueueItem {
                            message_id: mid,
                            packed_envelope: packed.clone(),
                            peer_addr: raven_core::encode_address(&pp),
                            state: DeliveryState::Queued,
                            created_at_ms: now_ms(),
                        })
                        .unwrap();
                }
                let addr: SocketAddr = peer_s.parse().unwrap_or_else(|e| {
                    eprintln!("peer parse: {e}");
                    std::process::exit(1);
                });
                let mut stream = TcpStream::connect(addr).await.unwrap_or_else(|e| {
                    eprintln!("connect: {e}");
                    std::process::exit(1);
                });
                write_frame(&mut stream, &packed).await.unwrap();
                {
                    let st = state.lock().await;
                    st.queue.mark_state(&mid, DeliveryState::Sent).unwrap();
                }
                eprintln!("raven-node: SENT message_id={}", hex::encode(mid));
                let st = state.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, st).await;
                });
            } else if let Some(peer_s) = peer.as_ref() {
                // Dial-only (e.g. C connects to B mock-BLE to receive).
                let addr: SocketAddr = peer_s.parse().unwrap_or_else(|e| {
                    eprintln!("peer parse: {e}");
                    std::process::exit(1);
                });
                let stream = TcpStream::connect(addr).await.unwrap_or_else(|e| {
                    eprintln!("connect: {e}");
                    std::process::exit(1);
                });
                eprintln!("raven-node: dialed {addr} (recv mode)");
                let st = state.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, st).await;
                });
            }

            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
            loop {
                if tokio::time::Instant::now() > deadline {
                    eprintln!("raven-node: timeout");
                    break;
                }
                {
                    let st = state.lock().await;
                    if exit_after_ack && st.got_ack {
                        eprintln!("raven-node: exit_after_ack");
                        break;
                    }
                    if exit_after_recv > 0 && st.recv_count >= exit_after_recv {
                        eprintln!("raven-node: exit_after_recv");
                        break;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        }
        Commands::Bridge {
            data_dir,
            lan_listen,
            ble_listen,
            write_lan_addr,
            write_ble_addr,
            write_status,
            timeout_secs,
        } => {
            if let Err(e) = bridge_run::run_bridge_daemon(
                data_dir,
                lan_listen,
                ble_listen,
                write_lan_addr,
                write_ble_addr,
                write_status,
                timeout_secs,
            )
            .await
            {
                eprintln!("bridge failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Status { data_dir } => {
            let policy = load_policy(&data_dir);
            let (pending, total) = match ForwardQueue::open(&bridge_run::forward_queue_path(&data_dir))
            {
                Ok(q) => (
                    q.count_pending().unwrap_or(0),
                    q.count_all().unwrap_or(0),
                ),
                Err(_) => (0, 0),
            };
            let snap = BridgeStatusSnapshot::from_policy(
                &policy,
                &["lan", "mock_ble"],
                pending,
                total,
            );
            println!("bridge={}", snap.bridge);
            println!("store={}", snap.store);
            println!("relay={}", snap.relay);
            println!("endpoint={}", snap.endpoint);
            println!("auto_policy={}", snap.auto_policy);
            println!("transports={}", snap.transports.join(","));
            println!("forward_queue_pending={}", snap.forward_queue_pending);
            println!("forward_queue_total={}", snap.forward_queue_total);
            println!("capabilities={}", snap.capabilities.join(","));
        }
        Commands::Flush {
            data_dir,
            peer,
            peer_pub_hex,
            timeout_secs,
        } => {
            let identity = load_or_err(&data_dir).unwrap_or_else(|e| {
                eprintln!("{e}");
                std::process::exit(1);
            });
            let queue = OutgoingQueue::open(&queue_path(&data_dir)).unwrap();
            let peer_pub = parse_pub_hex(&peer_pub_hex).unwrap();
            let pending = queue.pending().unwrap();
            eprintln!("raven-node: flushing {} pending", pending.len());
            let addr: SocketAddr = peer.parse().unwrap();
            let state = Arc::new(Mutex::new(NodeState {
                identity,
                queue,
                peer_pub: Some(peer_pub),
                origin_pub: None,
                ack_pub: None,
                recv_count: 0,
                got_ack: false,
            }));
            for item in pending {
                let mut stream = TcpStream::connect(addr).await.unwrap();
                write_frame(&mut stream, &item.packed_envelope).await.unwrap();
                {
                    let st = state.lock().await;
                    st.queue
                        .mark_state(&item.message_id, DeliveryState::Sent)
                        .unwrap();
                }
                let st = state.clone();
                let handle = tokio::spawn(async move {
                    let _ = handle_connection(stream, st).await;
                });
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(timeout_secs),
                    handle,
                )
                .await;
            }
            let st = state.lock().await;
            if st.got_ack {
                eprintln!("raven-node: flush got ACK");
            } else {
                eprintln!("raven-node: flush done (check pending)");
            }
        }
    }
}
