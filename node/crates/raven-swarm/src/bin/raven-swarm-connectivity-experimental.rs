//! Operator-only NAT traversal experiment.
//!
//! Compiling this target requires `experimental-nat-connectivity`; running it
//! requires `--enable-experimental-nat-connectivity`. It has no built-in
//! bootstrap, relay, rendezvous, or Raven service address.

use std::error::Error;
use std::time::Duration;

use clap::Parser;
use futures::StreamExt;
use libp2p::identity::Keypair;
use libp2p::relay::client::Event as RelayEvent;
use libp2p::swarm::SwarmEvent;
use libp2p::Multiaddr;
use raven_swarm::connectivity::{
    build_connectivity_swarm, relay_reservation_address, require_experimental_runtime_opt_in,
    ConnectivityProfile, RavenConnectivityBehaviourEvent,
};

const MAX_EXPERIMENT_SECONDS: u64 = 3_600;
const MAX_OPERATOR_DIALS: usize = 8;

#[derive(Debug, Parser)]
#[command(
    name = "raven-swarm-connectivity-experimental",
    about = "Production-disabled Raven NAT traversal experiment"
)]
struct Arguments {
    /// Required runtime acknowledgement in addition to the Cargo feature.
    #[arg(long, default_value_t = false)]
    enable_experimental_nat_connectivity: bool,

    #[arg(long, default_value = "/ip4/0.0.0.0/tcp/0")]
    listen_tcp: String,

    #[arg(long, default_value = "/ip4/0.0.0.0/udp/0/quic-v1")]
    listen_quic: String,

    /// Optional operator-supplied relay ending in `/p2p/<relay-peer>`.
    #[arg(long)]
    relay: Option<String>,

    /// Optional operator-supplied peer multiaddr; no peers are built in.
    #[arg(long)]
    dial: Vec<String>,

    #[arg(long, default_value_t = 60)]
    run_seconds: u64,
}

fn parse_address(raw: &str) -> Result<Multiaddr, Box<dyn Error + Send + Sync>> {
    raw.parse()
        .map_err(|_| "invalid operator-supplied multiaddr".into())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error + Send + Sync>> {
    let arguments = Arguments::parse();
    require_experimental_runtime_opt_in(arguments.enable_experimental_nat_connectivity)?;
    if arguments.run_seconds == 0 || arguments.run_seconds > MAX_EXPERIMENT_SECONDS {
        return Err("experiment duration is outside the bounded range".into());
    }
    if arguments.dial.len() > MAX_OPERATOR_DIALS {
        return Err("too many operator-supplied dial addresses".into());
    }

    let identity = Keypair::generate_ed25519();
    let mut swarm = build_connectivity_swarm(identity, ConnectivityProfile::default())
        .map_err(|_| "failed to build experimental connectivity profile")?;
    swarm
        .listen_on(parse_address(&arguments.listen_tcp)?)
        .map_err(|_| "failed to start TCP listener")?;
    swarm
        .listen_on(parse_address(&arguments.listen_quic)?)
        .map_err(|_| "failed to start QUIC listener")?;

    if let Some(relay) = arguments.relay.as_deref() {
        let relay = parse_address(relay)?;
        swarm
            .listen_on(relay_reservation_address(&relay)?)
            .map_err(|_| "failed to request relay reservation")?;
    }
    for address in &arguments.dial {
        swarm
            .dial(parse_address(address)?)
            .map_err(|_| "failed to queue operator-supplied dial")?;
    }

    println!("state=experimental_connectivity_enabled");
    println!("transport=tcp_quic_noise_yamux_relay_client");
    println!("discovery=operator_supplied_only");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(arguments.run_seconds);
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                println!("state=experiment_complete");
                return Ok(());
            }
            _ = tokio::signal::ctrl_c() => {
                println!("state=experiment_stopped");
                return Ok(());
            }
            event = swarm.select_next_some() => match event {
                SwarmEvent::NewListenAddr { .. } => println!("network=listener_ready"),
                SwarmEvent::ConnectionEstablished { .. } => {
                    println!("network=connection_established")
                }
                SwarmEvent::ConnectionClosed { .. } => println!("network=connection_closed"),
                SwarmEvent::IncomingConnectionError { .. } => {
                    println!("network=incoming_rejected")
                }
                SwarmEvent::OutgoingConnectionError { .. } => {
                    println!("network=outgoing_failed")
                }
                SwarmEvent::Behaviour(RavenConnectivityBehaviourEvent::AutoNat(event)) => {
                    if event.result.is_ok() {
                        println!("autonat=reachable")
                    } else {
                        println!("autonat=probe_failed")
                    }
                }
                SwarmEvent::Behaviour(RavenConnectivityBehaviourEvent::Dcutr(event)) => {
                    if event.result.is_ok() {
                        println!("dcutr=direct_connection_established")
                    } else {
                        println!("dcutr=upgrade_failed")
                    }
                }
                SwarmEvent::Behaviour(RavenConnectivityBehaviourEvent::Relay(event)) => {
                    match event {
                        RelayEvent::ReservationReqAccepted { renewal, .. } if renewal => {
                            println!("relay=reservation_renewed")
                        }
                        RelayEvent::ReservationReqAccepted { .. } => {
                            println!("relay=reservation_accepted")
                        }
                        RelayEvent::OutboundCircuitEstablished { .. } => {
                            println!("relay=outbound_circuit_established")
                        }
                        RelayEvent::InboundCircuitEstablished { .. } => {
                            println!("relay=inbound_circuit_established")
                        }
                    }
                }
                SwarmEvent::Behaviour(RavenConnectivityBehaviourEvent::Ping(event))
                    if event.result.is_err() =>
                {
                    println!("health=ping_failed")
                }
                _ => {}
            }
        }
    }
}
