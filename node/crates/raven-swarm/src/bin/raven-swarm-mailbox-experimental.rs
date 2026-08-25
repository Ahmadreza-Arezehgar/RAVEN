//! Explicitly feature-gated offline mailbox transport harness.
//!
//! This is intentionally a separate binary. Building or running the normal
//! `raven-swarm` does not advertise `/raven/offline-mailbox/1.0.0`.

use std::error::Error;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Parser, Subcommand};
use futures::StreamExt;
use libp2p::identity::Keypair;
use libp2p::multiaddr::Protocol;
use libp2p::request_response::{Event, Message, OutboundRequestId};
use libp2p::swarm::SwarmEvent;
use libp2p::{noise, tcp, yamux, Multiaddr, PeerId, Swarm, SwarmBuilder};
use raven_core::identity::Identity;
use raven_core::store_object::StoreObject;
use raven_swarm::mailbox::{
    mailbox_behaviour, unix_time_ms, MailboxBehaviour, MailboxRequest, MailboxResponse,
    MailboxRole, MailboxService, MAX_PAGE_OBJECTS, MAX_STORE_OBJECT_WIRE_BYTES,
};

#[derive(Parser, Debug)]
#[command(
    name = "raven-swarm-mailbox-experimental",
    about = "EXPERIMENTAL: bounded opaque Raven offline mailbox over libp2p"
)]
struct Cli {
    /// Required runtime acknowledgement in addition to the Cargo feature.
    #[arg(long, global = true, default_value_t = false)]
    allow_experimental_mailbox: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Persist and serve strict StoreObjectV1 rows. Zero timeout runs until SIGINT.
    Serve {
        #[arg(long)]
        data_dir: PathBuf,
        #[arg(long, default_value = "/ip4/127.0.0.1/tcp/0")]
        listen: String,
        #[arg(long)]
        write_multiaddr: Option<PathBuf>,
        #[arg(long)]
        write_peer_id: Option<PathBuf>,
        #[arg(long, default_value_t = 0)]
        timeout_secs: u64,
    },
    /// Deposit one already-packed, opaque StoreObjectV1.
    Put {
        #[arg(long)]
        data_dir: PathBuf,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_id: String,
        #[arg(long)]
        object_hex: String,
        #[arg(long, default_value_t = 15)]
        timeout_secs: u64,
    },
    /// Fetch one bounded page by a 16-byte rotating store_tag capability.
    Get {
        #[arg(long)]
        data_dir: PathBuf,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_id: String,
        #[arg(long)]
        store_tag_hex: String,
        /// Opaque 32-byte continuation token returned by a previous page.
        #[arg(long)]
        after_hex: Option<String>,
        #[arg(long, default_value_t = MAX_PAGE_OBJECTS)]
        limit: u16,
        #[arg(long, default_value_t = 15)]
        timeout_secs: u64,
    },
}

fn load_identity(data_dir: &Path) -> Result<Identity, Box<dyn Error>> {
    Ok(raven_core::load_or_create_identity(data_dir).map(|(identity, _)| identity)?)
}

fn libp2p_keypair(identity: &Identity) -> Keypair {
    use sha2::{Digest, Sha256};

    let mut hash = Sha256::new();
    hash.update(b"raven/libp2p-peer-key/v1");
    hash.update(identity.seed_bytes());
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&hash.finalize());
    Keypair::ed25519_from_bytes(seed).expect("domain-separated Ed25519 seed")
}

fn build_swarm(
    identity: &Identity,
    role: MailboxRole,
) -> Result<Swarm<MailboxBehaviour>, Box<dyn Error>> {
    Ok(
        SwarmBuilder::with_existing_identity(libp2p_keypair(identity))
            .with_tokio()
            .with_tcp(
                tcp::Config::default().nodelay(true),
                noise::Config::new,
                yamux::Config::default,
            )?
            .with_quic()
            .with_behaviour(|_| mailbox_behaviour(role))?
            .with_swarm_config(|config| {
                config.with_idle_connection_timeout(Duration::from_secs(30))
            })
            .build(),
    )
}

fn remote(peer: &str, peer_id: &str) -> Result<(Multiaddr, PeerId), Box<dyn Error>> {
    let address: Multiaddr = peer.parse()?;
    let peer_id: PeerId = peer_id.parse()?;
    Ok((address, peer_id))
}

fn dial_address(address: Multiaddr, peer_id: PeerId) -> Multiaddr {
    if address
        .iter()
        .any(|protocol| matches!(protocol, Protocol::P2p(_)))
    {
        address
    } else {
        address.with(Protocol::P2p(peer_id))
    }
}

async fn serve(
    data_dir: PathBuf,
    listen: String,
    write_multiaddr: Option<PathBuf>,
    write_peer_id: Option<PathBuf>,
    timeout_secs: u64,
) -> Result<(), Box<dyn Error>> {
    let identity = load_identity(&data_dir)?;
    let mut service = MailboxService::open(&data_dir)?;
    let mut swarm = build_swarm(&identity, MailboxRole::Server)?;
    let local_peer = *swarm.local_peer_id();
    swarm.listen_on(listen.parse()?)?;

    let deadline =
        (timeout_secs > 0).then(|| tokio::time::Instant::now() + Duration::from_secs(timeout_secs));
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Ok(()),
            _ = async {
                if let Some(deadline) = deadline {
                    tokio::time::sleep_until(deadline).await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => return Ok(()),
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        println!("listen_addr={address}");
                        println!("libp2p_peer_id={local_peer}");
                        if let Some(path) = &write_multiaddr {
                            std::fs::write(path, address.to_string())?;
                        }
                        if let Some(path) = &write_peer_id {
                            std::fs::write(path, local_peer.to_string())?;
                        }
                    }
                    SwarmEvent::Behaviour(Event::Message {
                        message: Message::Request { request, channel, .. },
                        ..
                    }) => {
                        let response = service.handle(request, unix_time_ms());
                        let accepted = matches!(response, MailboxResponse::Stored | MailboxResponse::Objects { .. });
                        if swarm.behaviour_mut().send_response(channel, response).is_err() {
                            eprintln!("mailbox_response_dropped");
                        } else {
                            println!("mailbox_request_complete accepted={}", u8::from(accepted));
                        }
                    }
                    SwarmEvent::Behaviour(Event::InboundFailure { error, .. }) => {
                        eprintln!("mailbox_inbound_failure error={error}");
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn request(
    data_dir: PathBuf,
    peer: String,
    peer_id: String,
    request: MailboxRequest,
    timeout_secs: u64,
) -> Result<MailboxResponse, Box<dyn Error>> {
    let identity = load_identity(&data_dir)?;
    let mut swarm = build_swarm(&identity, MailboxRole::Client)?;
    let (address, remote_peer) = remote(&peer, &peer_id)?;
    swarm.dial(dial_address(address, remote_peer))?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs.max(1));
    let mut request_id: Option<OutboundRequestId> = None;

    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => return Err("mailbox request timeout".into()),
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::ConnectionEstablished { peer_id: connected, .. }
                        if connected == remote_peer && request_id.is_none() => {
                        request_id = Some(swarm.behaviour_mut().send_request(&remote_peer, request.clone()));
                    }
                    SwarmEvent::OutgoingConnectionError { error, .. } => {
                        return Err(format!("mailbox dial failed: {error}").into());
                    }
                    SwarmEvent::Behaviour(Event::Message {
                        message: Message::Response { request_id: got, response },
                        ..
                    }) if Some(got) == request_id => return Ok(response),
                    SwarmEvent::Behaviour(Event::OutboundFailure { request_id: got, error, .. })
                        if Some(got) == request_id => {
                        return Err(format!("mailbox request failed: {error}").into());
                    }
                    _ => {}
                }
            }
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();
    if !cli.allow_experimental_mailbox {
        return Err("security hold: pass --allow-experimental-mailbox explicitly".into());
    }

    match cli.command {
        Command::Serve {
            data_dir,
            listen,
            write_multiaddr,
            write_peer_id,
            timeout_secs,
        } => {
            serve(
                data_dir,
                listen,
                write_multiaddr,
                write_peer_id,
                timeout_secs,
            )
            .await
        }
        Command::Put {
            data_dir,
            peer,
            peer_id,
            object_hex,
            timeout_secs,
        } => {
            if object_hex.len() > MAX_STORE_OBJECT_WIRE_BYTES.saturating_mul(2) {
                return Err("store object exceeds hard limit".into());
            }
            let object = hex::decode(object_hex)?;
            StoreObject::unpack(&object)
                .map_err(|error| format!("invalid StoreObjectV1: {error}"))?;
            match request(
                data_dir,
                peer,
                peer_id,
                MailboxRequest::Put(object),
                timeout_secs,
            )
            .await?
            {
                MailboxResponse::Stored => {
                    println!("stored=1");
                    Ok(())
                }
                MailboxResponse::Rejected(code) => {
                    Err(format!("mailbox rejected put: {code:?}").into())
                }
                _ => Err("unexpected mailbox put response".into()),
            }
        }
        Command::Get {
            data_dir,
            peer,
            peer_id,
            store_tag_hex,
            after_hex,
            limit,
            timeout_secs,
        } => {
            let tag = hex::decode(store_tag_hex)?;
            if tag.len() != 16 {
                return Err("store_tag_hex must be exactly 16 bytes".into());
            }
            let mut store_tag = [0u8; 16];
            store_tag.copy_from_slice(&tag);
            let after = match after_hex {
                Some(value) => {
                    let decoded = hex::decode(value)?;
                    if decoded.len() != 32 {
                        return Err("after_hex must be exactly 32 bytes".into());
                    }
                    let mut token = [0u8; 32];
                    token.copy_from_slice(&decoded);
                    Some(token)
                }
                None => None,
            };
            match request(
                data_dir,
                peer,
                peer_id,
                MailboxRequest::Get {
                    store_tag,
                    after,
                    limit,
                },
                timeout_secs,
            )
            .await?
            {
                MailboxResponse::Objects {
                    next_cursor,
                    objects,
                } => {
                    println!("object_count={}", objects.len());
                    for object in objects {
                        let decoded = StoreObject::unpack(&object)
                            .map_err(|error| format!("store returned invalid object: {error}"))?;
                        if decoded.store_tag != store_tag {
                            return Err("store returned an object for a different store_tag".into());
                        }
                        println!("object_hex={}", hex::encode(object));
                    }
                    match next_cursor {
                        Some(value) => println!("next_cursor={}", hex::encode(value)),
                        None => println!("next_cursor=end"),
                    }
                    Ok(())
                }
                MailboxResponse::Rejected(code) => {
                    Err(format!("mailbox rejected get: {code:?}").into())
                }
                _ => Err("unexpected mailbox get response".into()),
            }
        }
    }
}
