//! Two-node libp2p swarm: TCP (+ optional QUIC listen) + Noise/Yamux + Kad put/get
//! of signed `PeerRecord`. Separates libp2p PeerId from Raven Ed25519 identity.
//! No FastAPI / HTTP API in path.

use std::error::Error;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use futures::StreamExt;
use libp2p::identity::Keypair;
use libp2p::kad::store::{MemoryStore, RecordStore};
use libp2p::kad::{self, Mode, Quorum, Record, RecordKey};
use libp2p::multiaddr::Protocol;
use libp2p::swarm::{NetworkBehaviour, SwarmEvent};
use libp2p::{identify, noise, ping, tcp, yamux, Multiaddr, PeerId, StreamProtocol, SwarmBuilder};
use raven_core::bootstrap::{load_bootstrap, save_bootstrap, BootstrapConfig};
use raven_core::discovery::PeerRecord;
use raven_core::identity::Identity;
use raven_core::{CAP_INTERNET, CAP_RELAY};

const RAVEN_KAD: StreamProtocol = StreamProtocol::new("/raven/kad/1.0.0");

#[derive(NetworkBehaviour)]
struct RavenBehaviour {
    kad: kad::Behaviour<MemoryStore>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

#[derive(Parser, Debug)]
#[command(
    name = "raven-swarm",
    about = "RAVEN libp2p swarm smoke (TCP/QUIC + Kad)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Listen, publish signed PeerRecord into Kad, wait for inbound dial.
    Serve {
        #[arg(long, default_value = "./raven-swarm-data")]
        data_dir: PathBuf,
        #[arg(long, default_value = "/ip4/127.0.0.1/tcp/0")]
        listen: String,
        /// Also listen QUIC on UDP (same host, port+1 or explicit).
        #[arg(long, default_value_t = true)]
        quic: bool,
        #[arg(long)]
        write_multiaddr: Option<PathBuf>,
        #[arg(long)]
        write_peer_id: Option<PathBuf>,
        #[arg(long, default_value_t = 30)]
        timeout_secs: u64,
        /// Exit after successful Kad put of our peer record.
        #[arg(long, default_value_t = false)]
        exit_after_put: bool,
    },
    /// Dial peer, fetch signed PeerRecord via Kad get, verify Ed25519.
    Dial {
        #[arg(long, default_value = "./raven-swarm-data-b")]
        data_dir: PathBuf,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_id: String,
        /// Raven Ed25519 pub hex whose DHT key we GET.
        #[arg(long)]
        raven_pub_hex: String,
        #[arg(long, default_value_t = 30)]
        timeout_secs: u64,
    },
    /// Write bootstrap.json for manual-peer-only startup (§30).
    BootstrapInit {
        #[arg(long, default_value = "./raven-swarm-data")]
        data_dir: PathBuf,
        /// Manual multiaddr (required for manual-peer-only proof).
        #[arg(long)]
        manual_peer: String,
        /// Extra custom bootstrap multiaddrs.
        #[arg(long)]
        custom: Vec<String>,
        /// Disable Raven-provided defaults (always empty in V1 anyway).
        #[arg(long, default_value_t = true)]
        no_raven_defaults: bool,
    },
    /// Print effective bootstrap peers from data-dir config.
    BootstrapShow {
        #[arg(long, default_value = "./raven-swarm-data")]
        data_dir: PathBuf,
    },
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn load_or_create_identity(data_dir: &std::path::Path) -> Result<Identity, Box<dyn Error>> {
    Ok(raven_core::load_or_create_identity(data_dir).map(|(id, _)| id)?)
}

fn libp2p_keypair_from_raven(id: &Identity) -> Keypair {
    // Separate namespaces: derive libp2p key from a domain-separated hash of the
    // Raven seed so PeerId ≠ Raven address, but is stable per data-dir.
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(b"raven/libp2p-peer-key/v1");
    h.update(id.seed_bytes());
    let d = h.finalize();
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&d);
    Keypair::ed25519_from_bytes(seed).expect("ed25519 key")
}

fn build_swarm(id: &Identity) -> Result<libp2p::Swarm<RavenBehaviour>, Box<dyn Error>> {
    let kp = libp2p_keypair_from_raven(id);
    let peer_id = kp.public().to_peer_id();
    let swarm = SwarmBuilder::with_existing_identity(kp)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_behaviour(|key| {
            let store = MemoryStore::new(peer_id);
            let mut kad_cfg = kad::Config::new(RAVEN_KAD);
            kad_cfg.set_query_timeout(Duration::from_secs(20));
            let mut kad = kad::Behaviour::with_config(peer_id, store, kad_cfg);
            kad.set_mode(Some(Mode::Server));
            let identify = identify::Behaviour::new(identify::Config::new(
                "/raven/identify/1.0.0".into(),
                key.public(),
            ));
            let ping = ping::Behaviour::default();
            RavenBehaviour {
                kad,
                identify,
                ping,
            }
        })?
        .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
        .build();
    Ok(swarm)
}

async fn cmd_serve(
    data_dir: PathBuf,
    listen: String,
    quic: bool,
    write_multiaddr: Option<PathBuf>,
    write_peer_id: Option<PathBuf>,
    timeout_secs: u64,
    exit_after_put: bool,
) -> Result<(), Box<dyn Error>> {
    let raven_id = load_or_create_identity(&data_dir)?;
    let mut swarm = build_swarm(&raven_id)?;
    let local_peer = *swarm.local_peer_id();
    println!("raven_pub_hex={}", hex::encode(raven_id.public_key_bytes()));
    println!("libp2p_peer_id={local_peer}");
    println!("note=libp2p PeerId is domain-separated from Raven identity");

    let listen_maddr: Multiaddr = listen.parse()?;
    swarm.listen_on(listen_maddr.clone())?;
    if quic {
        // Prefer explicit QUIC listen on UDP; derive from TCP listen when possible.
        let quic_addr = if listen.contains("/tcp/") {
            let tcp_port = listen_maddr
                .iter()
                .find_map(|p| match p {
                    Protocol::Tcp(p) => Some(p),
                    _ => None,
                })
                .unwrap_or(0);
            let mut q = Multiaddr::empty();
            for p in listen_maddr.iter() {
                match p {
                    Protocol::Tcp(_) => {
                        q.push(Protocol::Udp(if tcp_port == 0 {
                            0
                        } else {
                            tcp_port.saturating_add(1)
                        }));
                        q.push(Protocol::QuicV1);
                    }
                    other => q.push(other),
                }
            }
            q
        } else {
            "/ip4/127.0.0.1/udp/0/quic-v1".parse()?
        };
        match swarm.listen_on(quic_addr.clone()) {
            Ok(_) => println!("quic_listen_requested={quic_addr}"),
            Err(e) => println!("quic_listen_skip={e}"),
        }
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);
    let mut announced = false;
    let mut put_done = false;
    let mut listened: Option<Multiaddr> = None;

    loop {
        if tokio::time::Instant::now() > deadline {
            return Err("serve timeout".into());
        }
        tokio::select! {
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        println!("listen_addr={address}");
                        // Prefer TCP for the smoke dial address.
                        if address.iter().any(|p| matches!(p, Protocol::Tcp(_))) {
                            listened = Some(address.clone());
                            if let Some(ref path) = write_multiaddr {
                                std::fs::write(path, address.to_string())?;
                            }
                            if let Some(ref path) = write_peer_id {
                                std::fs::write(path, local_peer.to_string())?;
                            }
                            if !announced {
                                announced = true;
                                let dial = address.to_string();
                                let rec = PeerRecord {
                                    dial: dial.clone(),
                                    ed25519_pub: [0u8; 32],
                                    caps: CAP_INTERNET | CAP_RELAY,
                                    expires_at_ms: now_ms() + 3_600_000,
                                    signature: [0u8; 64],
                                }
                                .sign(&raven_id)?;
                                let key = RecordKey::new(&rec.dht_key());
                                let value = rec.encode()?;
                                let record = Record {
                                    key: key.clone(),
                                    value,
                                    publisher: Some(local_peer),
                                    expires: None,
                                };
                                // Local store first (solo-node Quorum put would fail).
                                swarm
                                    .behaviour_mut()
                                    .kad
                                    .store_mut()
                                    .put(record.clone())
                                    .map_err(|e| format!("local kad put: {e}"))?;
                                println!("kad_put_ok key={}", hex::encode(rec.dht_key()));
                                put_done = true;
                                // Also start a network put once a peer dials (replication).
                                let _ = swarm
                                    .behaviour_mut()
                                    .kad
                                    .put_record(record, Quorum::One);
                                if exit_after_put {
                                    return Ok(());
                                }
                            }
                        }
                    }
                    SwarmEvent::Behaviour(RavenBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed {
                        result: kad::QueryResult::PutRecord(Ok(_)),
                        ..
                    })) => {
                        println!("kad_network_put_ok");
                    }
                    SwarmEvent::Behaviour(RavenBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed {
                        result: kad::QueryResult::PutRecord(Err(e)),
                        ..
                    })) => {
                        // Solo listen: network quorum may fail until a peer dials — local put already OK.
                        println!("kad_network_put_pending={e}");
                    }
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                        println!("connection_established peer={peer_id}");
                        if put_done {
                            // Keep serving a bit so dialer can GET; if dialer already done, smoke script kills us.
                        }
                    }
                    SwarmEvent::IncomingConnection { .. } => {
                        println!("incoming_connection");
                    }
                    _ => {}
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {
                let _ = &listened;
            }
        }
    }
}

async fn cmd_dial(
    data_dir: PathBuf,
    peer: String,
    peer_id: String,
    raven_pub_hex: String,
    timeout_secs: u64,
) -> Result<(), Box<dyn Error>> {
    let raven_id = load_or_create_identity(&data_dir)?;
    let mut swarm = build_swarm(&raven_id)?;
    let remote_peer: PeerId = peer_id.parse()?;
    let remote_addr: Multiaddr = peer.parse()?;

    // Honor bootstrap.json if present (manual peers only path).
    let boot = load_bootstrap(&data_dir);
    if boot.manual_peer_only_ok() {
        println!("bootstrap_mode=manual_peer_only");
    } else {
        println!(
            "bootstrap_mode=config_effective count={}",
            boot.effective_peers().len()
        );
    }
    for p in boot.effective_peers() {
        println!("bootstrap_peer={p}");
    }

    swarm
        .behaviour_mut()
        .kad
        .add_address(&remote_peer, remote_addr.clone());
    swarm.dial(remote_addr.with(Protocol::P2p(remote_peer)))?;

    let pub_bytes = hex::decode(raven_pub_hex.trim())?;
    if pub_bytes.len() != 32 {
        return Err("raven_pub_hex must be 32 bytes".into());
    }
    let mut raven_pub = [0u8; 32];
    raven_pub.copy_from_slice(&pub_bytes);
    // DHT key same as PeerRecord::dht_key
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(b"rvn1/peer-key");
    hasher.update(raven_pub);
    let dht_key: [u8; 32] = hasher.finalize().into();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);
    let mut connected = false;
    let mut get_started = false;

    loop {
        if tokio::time::Instant::now() > deadline {
            return Err("dial timeout".into());
        }
        tokio::select! {
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                        println!("connection_established peer={peer_id}");
                        connected = true;
                        if !get_started {
                            get_started = true;
                            let key = RecordKey::new(&dht_key);
                            swarm.behaviour_mut().kad.get_record(key);
                            println!("kad_get_started key={}", hex::encode(dht_key));
                        }
                    }
                    SwarmEvent::OutgoingConnectionError { error, .. } => {
                        return Err(format!("dial error: {error}").into());
                    }
                    SwarmEvent::Behaviour(RavenBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed {
                        result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(peer_rec))),
                        ..
                    })) => {
                        let rec = PeerRecord::decode(&peer_rec.record.value)?;
                        rec.verify(now_ms())?;
                        if rec.ed25519_pub != raven_pub {
                            return Err("peer record pub mismatch".into());
                        }
                        println!("kad_get_ok dial={}", rec.dial);
                        println!("peer_record_verified=1");
                        if connected {
                            println!("=== LIBP2P SWARM DIAL+KAD OK (no FastAPI) ===");
                            return Ok(());
                        }
                    }
                    SwarmEvent::Behaviour(RavenBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed {
                        result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FinishedWithNoAdditionalRecord { .. })),
                        ..
                    })) => {
                        // keep waiting for FoundRecord
                    }
                    SwarmEvent::Behaviour(RavenBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed {
                        result: kad::QueryResult::GetRecord(Err(e)),
                        ..
                    })) => {
                        return Err(format!("kad get failed: {e}").into());
                    }
                    _ => {}
                }
            }
        }
    }
}

fn cmd_bootstrap_init(
    data_dir: PathBuf,
    manual_peer: String,
    custom: Vec<String>,
    no_raven_defaults: bool,
) -> Result<(), Box<dyn Error>> {
    std::fs::create_dir_all(&data_dir)?;
    let mut cfg = BootstrapConfig::default();
    if no_raven_defaults {
        cfg.remove_raven_defaults();
    }
    cfg.manual_peers.push(manual_peer);
    for c in custom {
        cfg.add_custom(c);
    }
    save_bootstrap(&data_dir, &cfg)?;
    println!(
        "bootstrap_path={}",
        data_dir.join("bootstrap.json").display()
    );
    println!("manual_peer_only={}", cfg.manual_peer_only_ok());
    println!("effective_count={}", cfg.effective_peers().len());
    Ok(())
}

fn cmd_bootstrap_show(data_dir: PathBuf) -> Result<(), Box<dyn Error>> {
    let cfg = load_bootstrap(&data_dir);
    println!("use_raven_defaults={}", cfg.use_raven_defaults);
    println!("raven_defaults_count={}", cfg.raven_defaults.len());
    println!("custom_count={}", cfg.custom.len());
    println!("manual_count={}", cfg.manual_peers.len());
    println!("manual_peer_only={}", cfg.manual_peer_only_ok());
    for p in cfg.effective_peers() {
        println!("peer={p}");
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();
    match cli.cmd {
        Commands::Serve {
            data_dir,
            listen,
            quic,
            write_multiaddr,
            write_peer_id,
            timeout_secs,
            exit_after_put,
        } => {
            cmd_serve(
                data_dir,
                listen,
                quic,
                write_multiaddr,
                write_peer_id,
                timeout_secs,
                exit_after_put,
            )
            .await
        }
        Commands::Dial {
            data_dir,
            peer,
            peer_id,
            raven_pub_hex,
            timeout_secs,
        } => cmd_dial(data_dir, peer, peer_id, raven_pub_hex, timeout_secs).await,
        Commands::BootstrapInit {
            data_dir,
            manual_peer,
            custom,
            no_raven_defaults,
        } => cmd_bootstrap_init(data_dir, manual_peer, custom, no_raven_defaults),
        Commands::BootstrapShow { data_dir } => cmd_bootstrap_show(data_dir),
    }
}
