//! Bounded, experimental NAT traversal composition for Raven.
//!
//! This module is not part of default builds. Enabling the Cargo feature only
//! makes the reusable profile available; the companion binary also requires a
//! separate runtime acknowledgement. It never contains a bootstrap, relay, or
//! AutoNAT server address.

use std::error::Error;
use std::fmt;
use std::num::{NonZeroU8, NonZeroUsize};
use std::time::Duration;

use libp2p::connection_limits::{self, ConnectionLimits};
use libp2p::identity::Keypair;
use libp2p::multiaddr::Protocol;
use libp2p::swarm::NetworkBehaviour;
use libp2p::{
    autonat, dcutr, identify, noise, ping, relay, tcp, yamux, Multiaddr, Swarm, SwarmBuilder,
};
use rand::rngs::OsRng;

/// Default/release Raven binaries do not instantiate this behaviour.
pub const PRODUCTION_NAT_CONNECTIVITY_ENABLED: bool = false;
pub const IDENTIFY_PROTOCOL_V1: &str = "/raven/connectivity/1.0.0";

pub const MAX_PENDING_CONNECTIONS: u32 = 64;
pub const MAX_ESTABLISHED_CONNECTIONS: u32 = 128;
pub const MAX_CONNECTIONS_PER_PEER: u32 = 4;
pub const MAX_AUTONAT_CANDIDATES: usize = 16;

/// Every dimension is finite. A value of zero deliberately disables that
/// direction, which is useful for a receive-only or dial-only experiment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionBudget {
    pub pending_incoming: u32,
    pub pending_outgoing: u32,
    pub established_incoming: u32,
    pub established_outgoing: u32,
    pub established_total: u32,
    pub established_per_peer: u32,
}

impl Default for ConnectionBudget {
    fn default() -> Self {
        Self {
            pending_incoming: 8,
            pending_outgoing: 8,
            established_incoming: 24,
            established_outgoing: 16,
            established_total: 32,
            established_per_peer: 2,
        }
    }
}

impl ConnectionBudget {
    fn validate(self) -> Result<(), ConnectivityConfigError> {
        if self.pending_incoming > MAX_PENDING_CONNECTIONS
            || self.pending_outgoing > MAX_PENDING_CONNECTIONS
        {
            return Err(ConnectivityConfigError::new(
                "pending connection budget exceeds hard maximum",
            ));
        }
        if self.established_incoming > MAX_ESTABLISHED_CONNECTIONS
            || self.established_outgoing > MAX_ESTABLISHED_CONNECTIONS
            || self.established_total > MAX_ESTABLISHED_CONNECTIONS
        {
            return Err(ConnectivityConfigError::new(
                "established connection budget exceeds hard maximum",
            ));
        }
        if self.established_per_peer > MAX_CONNECTIONS_PER_PEER {
            return Err(ConnectivityConfigError::new(
                "per-peer connection budget exceeds hard maximum",
            ));
        }
        if self.established_per_peer > self.established_total {
            return Err(ConnectivityConfigError::new(
                "per-peer connection budget exceeds total budget",
            ));
        }
        Ok(())
    }

    fn into_behaviour(self) -> connection_limits::Behaviour {
        let limits = ConnectionLimits::default()
            .with_max_pending_incoming(Some(self.pending_incoming))
            .with_max_pending_outgoing(Some(self.pending_outgoing))
            .with_max_established_incoming(Some(self.established_incoming))
            .with_max_established_outgoing(Some(self.established_outgoing))
            .with_max_established(Some(self.established_total))
            .with_max_established_per_peer(Some(self.established_per_peer));
        connection_limits::Behaviour::new(limits)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectivityProfile {
    pub connections: ConnectionBudget,
    pub connection_timeout: Duration,
    pub idle_connection_timeout: Duration,
    pub ping_interval: Duration,
    pub ping_timeout: Duration,
    pub identify_interval: Duration,
    pub autonat_probe_interval: Duration,
    pub autonat_max_candidates: usize,
}

impl Default for ConnectivityProfile {
    fn default() -> Self {
        Self {
            connections: ConnectionBudget::default(),
            connection_timeout: Duration::from_secs(10),
            idle_connection_timeout: Duration::from_secs(90),
            ping_interval: Duration::from_secs(15),
            ping_timeout: Duration::from_secs(5),
            identify_interval: Duration::from_secs(60),
            autonat_probe_interval: Duration::from_secs(30),
            autonat_max_candidates: 8,
        }
    }
}

impl ConnectivityProfile {
    pub fn validate(&self) -> Result<(), ConnectivityConfigError> {
        self.connections.validate()?;
        if self.connection_timeout.is_zero()
            || self.idle_connection_timeout.is_zero()
            || self.ping_interval.is_zero()
            || self.ping_timeout.is_zero()
            || self.identify_interval.is_zero()
            || self.autonat_probe_interval.is_zero()
        {
            return Err(ConnectivityConfigError::new(
                "connectivity durations must be nonzero",
            ));
        }
        if self.ping_timeout >= self.ping_interval {
            return Err(ConnectivityConfigError::new(
                "ping timeout must be shorter than ping interval",
            ));
        }
        if self.autonat_max_candidates == 0 || self.autonat_max_candidates > MAX_AUTONAT_CANDIDATES
        {
            return Err(ConnectivityConfigError::new(
                "AutoNAT candidate budget is outside the hard range",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectivityConfigError {
    message: &'static str,
}

impl ConnectivityConfigError {
    const fn new(message: &'static str) -> Self {
        Self { message }
    }

    pub const fn message(self) -> &'static str {
        self.message
    }
}

impl fmt::Display for ConnectivityConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message)
    }
}

impl Error for ConnectivityConfigError {}

/// The feature gate is intentionally insufficient on its own. Callers that
/// expose the experiment must collect a distinct runtime acknowledgement.
pub fn require_experimental_runtime_opt_in(
    acknowledged: bool,
) -> Result<(), ConnectivityConfigError> {
    if acknowledged {
        Ok(())
    } else {
        Err(ConnectivityConfigError::new(
            "experimental NAT connectivity requires explicit runtime opt-in",
        ))
    }
}

/// Convert an operator-supplied relay address ending in `/p2p/<peer>` into a
/// reservation listener. Raven ships no relay address and never selects one
/// implicitly.
pub fn relay_reservation_address(
    relay_address: &Multiaddr,
) -> Result<Multiaddr, ConnectivityConfigError> {
    let mut peer_components = 0usize;
    let mut last_is_peer = false;
    for component in relay_address.iter() {
        if matches!(component, Protocol::P2pCircuit) {
            return Err(ConnectivityConfigError::new(
                "relay address already contains p2p-circuit",
            ));
        }
        if matches!(component, Protocol::P2p(_)) {
            peer_components += 1;
            last_is_peer = true;
        } else {
            last_is_peer = false;
        }
    }
    if peer_components != 1 || !last_is_peer {
        return Err(ConnectivityConfigError::new(
            "relay address must end in exactly one p2p peer component",
        ));
    }
    let mut reservation = relay_address.clone();
    reservation.push(Protocol::P2pCircuit);
    Ok(reservation)
}

/// Relay is client-only and AutoNAT is the v2 client behaviour. There is no
/// relay service or AutoNAT server in this profile.
#[derive(NetworkBehaviour)]
pub struct RavenConnectivityBehaviour {
    pub relay: relay::client::Behaviour,
    pub dcutr: dcutr::Behaviour,
    pub auto_nat: autonat::v2::client::Behaviour,
    pub identify: identify::Behaviour,
    pub ping: ping::Behaviour,
    limits: connection_limits::Behaviour,
}

/// Compose direct TCP and QUIC transports with the relay client transport.
/// TCP and relay streams both use Noise authentication and Yamux; QUIC uses
/// QUIC's authenticated transport security.
pub fn build_connectivity_swarm(
    identity: Keypair,
    profile: ConnectivityProfile,
) -> Result<Swarm<RavenConnectivityBehaviour>, Box<dyn Error + Send + Sync>> {
    profile.validate()?;

    let behaviour_profile = profile.clone();
    let swarm = SwarmBuilder::with_existing_identity(identity)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_relay_client(noise::Config::new, yamux::Config::default)?
        .with_behaviour(move |key, relay| {
            let local_peer_id = key.public().to_peer_id();
            let auto_nat_config = autonat::v2::client::Config::default()
                .with_max_candidates(behaviour_profile.autonat_max_candidates)
                .with_probe_interval(behaviour_profile.autonat_probe_interval);
            let identify_config =
                identify::Config::new(IDENTIFY_PROTOCOL_V1.to_owned(), key.public())
                    .with_agent_version("raven-connectivity-experimental/1".to_owned())
                    .with_interval(behaviour_profile.identify_interval)
                    .with_push_listen_addr_updates(true)
                    .with_cache_size(64);
            let ping_config = ping::Config::new()
                .with_interval(behaviour_profile.ping_interval)
                .with_timeout(behaviour_profile.ping_timeout);

            RavenConnectivityBehaviour {
                relay,
                dcutr: dcutr::Behaviour::new(local_peer_id),
                auto_nat: autonat::v2::client::Behaviour::new(OsRng, auto_nat_config),
                identify: identify::Behaviour::new(identify_config),
                ping: ping::Behaviour::new(ping_config),
                limits: behaviour_profile.connections.into_behaviour(),
            }
        })?
        .with_swarm_config(move |config| {
            config
                .with_idle_connection_timeout(profile.idle_connection_timeout)
                .with_notify_handler_buffer_size(
                    NonZeroUsize::new(32).expect("constant is nonzero"),
                )
                .with_per_connection_event_buffer_size(32)
                .with_dial_concurrency_factor(NonZeroU8::new(4).expect("constant is nonzero"))
                .with_max_negotiating_inbound_streams(64)
        })
        .with_connection_timeout(profile.connection_timeout)
        .build();

    Ok(swarm)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use futures::StreamExt;
    use libp2p::identity::Keypair;
    use libp2p::multiaddr::Protocol;
    use libp2p::swarm::SwarmEvent;
    use libp2p::{identify, noise, relay, tcp, yamux, Multiaddr, SwarmBuilder};

    use super::*;

    fn fixed_identity(seed_byte: u8) -> Keypair {
        Keypair::ed25519_from_bytes([seed_byte; 32]).expect("fixed Ed25519 test seed")
    }

    #[derive(NetworkBehaviour)]
    struct TestRelayBehaviour {
        relay: relay::Behaviour,
        identify: identify::Behaviour,
    }

    fn build_test_relay(identity: Keypair) -> Swarm<TestRelayBehaviour> {
        let local_peer_id = identity.public().to_peer_id();
        SwarmBuilder::with_existing_identity(identity)
            .with_tokio()
            .with_tcp(
                tcp::Config::default().nodelay(true),
                noise::Config::new,
                yamux::Config::default,
            )
            .expect("relay TCP transport")
            .with_behaviour(move |key| TestRelayBehaviour {
                relay: relay::Behaviour::new(
                    local_peer_id,
                    relay::Config {
                        reservation_duration: Duration::from_secs(60),
                        ..Default::default()
                    },
                ),
                identify: identify::Behaviour::new(identify::Config::new(
                    "/raven/connectivity-test-relay/1.0.0".to_owned(),
                    key.public(),
                )),
            })
            .expect("relay behaviour")
            .with_swarm_config(|config| {
                config.with_idle_connection_timeout(Duration::from_secs(30))
            })
            .build()
    }

    async fn tcp_listener_for<B>(swarm: &mut Swarm<B>) -> Multiaddr
    where
        B: NetworkBehaviour,
    {
        swarm
            .listen_on("/ip4/127.0.0.1/tcp/0".parse().expect("literal multiaddr"))
            .expect("listen request");
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let SwarmEvent::NewListenAddr { address, .. } = swarm.select_next_some().await {
                    if address.iter().any(|part| matches!(part, Protocol::Tcp(_))) {
                        return address;
                    }
                }
            }
        })
        .await
        .expect("listener timeout")
    }

    async fn quic_listener(swarm: &mut Swarm<RavenConnectivityBehaviour>) -> Multiaddr {
        swarm
            .listen_on(
                "/ip4/127.0.0.1/udp/0/quic-v1"
                    .parse()
                    .expect("literal multiaddr"),
            )
            .expect("listen request");
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let SwarmEvent::NewListenAddr { address, .. } = swarm.select_next_some().await {
                    if address.iter().any(|part| matches!(part, Protocol::QuicV1)) {
                        return address;
                    }
                }
            }
        })
        .await
        .expect("listener timeout")
    }

    async fn assert_nodes_connect(
        listener: &mut Swarm<RavenConnectivityBehaviour>,
        dialer: &mut Swarm<RavenConnectivityBehaviour>,
        address: Multiaddr,
    ) {
        let listener_peer = *listener.local_peer_id();
        dialer
            .dial(address.with(Protocol::P2p(listener_peer)))
            .expect("dial request");

        let connected = tokio::time::timeout(Duration::from_secs(5), async {
            let mut listener_connected = false;
            let mut dialer_connected = false;
            loop {
                tokio::select! {
                    event = listener.select_next_some() => {
                        if matches!(event, SwarmEvent::ConnectionEstablished { .. }) {
                            listener_connected = true;
                        }
                    }
                    event = dialer.select_next_some() => {
                        if matches!(event, SwarmEvent::ConnectionEstablished { .. }) {
                            dialer_connected = true;
                        }
                    }
                }
                if listener_connected && dialer_connected {
                    return true;
                }
            }
        })
        .await
        .expect("connection timeout");
        assert!(connected);
    }

    #[test]
    fn runtime_gate_and_default_budgets_are_fixed() {
        assert_eq!(
            require_experimental_runtime_opt_in(false)
                .expect_err("runtime gate")
                .message(),
            "experimental NAT connectivity requires explicit runtime opt-in"
        );
        require_experimental_runtime_opt_in(true).expect("explicit acknowledgement");
        let profile = ConnectivityProfile::default();
        profile.validate().expect("default profile");
        assert_eq!(profile.connections.established_total, 32);
        assert_eq!(profile.connections.established_per_peer, 2);
        assert_eq!(profile.autonat_max_candidates, 8);
    }

    #[test]
    fn relay_reservation_is_operator_supplied_and_canonical() {
        let relay_peer = fixed_identity(0x31).public().to_peer_id();
        let relay: Multiaddr = format!("/ip4/127.0.0.1/tcp/41001/p2p/{relay_peer}")
            .parse()
            .expect("relay address");
        let reservation = relay_reservation_address(&relay).expect("reservation address");
        assert!(matches!(
            reservation.iter().last(),
            Some(Protocol::P2pCircuit)
        ));

        assert!(relay_reservation_address(
            &"/ip4/127.0.0.1/tcp/41001"
                .parse()
                .expect("address without peer")
        )
        .is_err());
        assert!(relay_reservation_address(&reservation).is_err());
    }

    #[test]
    fn unsafe_budget_and_timing_are_rejected() {
        let mut profile = ConnectivityProfile::default();
        profile.connections.pending_outgoing = MAX_PENDING_CONNECTIONS + 1;
        assert_eq!(
            profile
                .validate()
                .expect_err("oversized pending budget")
                .message(),
            "pending connection budget exceeds hard maximum"
        );

        let mut profile = ConnectivityProfile::default();
        profile.connections.established_per_peer = MAX_CONNECTIONS_PER_PEER + 1;
        assert_eq!(
            profile
                .validate()
                .expect_err("oversized peer budget")
                .message(),
            "per-peer connection budget exceeds hard maximum"
        );

        let mut profile = ConnectivityProfile::default();
        profile.ping_timeout = profile.ping_interval;
        assert_eq!(
            profile
                .validate()
                .expect_err("invalid ping timing")
                .message(),
            "ping timeout must be shorter than ping interval"
        );
    }

    #[tokio::test]
    async fn fixed_localhost_nodes_connect_over_noise_tcp() {
        let mut listener =
            build_connectivity_swarm(fixed_identity(0x41), ConnectivityProfile::default())
                .expect("listener swarm");
        let mut dialer =
            build_connectivity_swarm(fixed_identity(0x42), ConnectivityProfile::default())
                .expect("dialer swarm");

        let address = tcp_listener_for(&mut listener).await;
        assert_nodes_connect(&mut listener, &mut dialer, address).await;
    }

    #[tokio::test]
    async fn fixed_localhost_nodes_connect_over_authenticated_quic() {
        let mut listener =
            build_connectivity_swarm(fixed_identity(0x45), ConnectivityProfile::default())
                .expect("listener swarm");
        let mut dialer =
            build_connectivity_swarm(fixed_identity(0x46), ConnectivityProfile::default())
                .expect("dialer swarm");

        let address = quic_listener(&mut listener).await;
        assert_nodes_connect(&mut listener, &mut dialer, address).await;
    }

    #[tokio::test]
    async fn operator_supplied_local_relay_accepts_a_client_reservation() {
        let mut relay = build_test_relay(fixed_identity(0x61));
        let relay_peer = *relay.local_peer_id();
        let relay_address = tcp_listener_for(&mut relay).await;
        relay.add_external_address(relay_address.clone());

        let mut client =
            build_connectivity_swarm(fixed_identity(0x62), ConnectivityProfile::default())
                .expect("client swarm");
        let _client_direct_address = tcp_listener_for(&mut client).await;
        let relay_dial_address = relay_address.with(Protocol::P2p(relay_peer));
        let reservation = relay_reservation_address(&relay_dial_address)
            .expect("operator relay reservation address");
        client
            .listen_on(reservation)
            .expect("relay reservation request");

        let accepted = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                tokio::select! {
                    _ = relay.select_next_some() => {}
                    event = client.select_next_some() => {
                        if matches!(
                            event,
                            SwarmEvent::Behaviour(RavenConnectivityBehaviourEvent::Relay(
                                relay::client::Event::ReservationReqAccepted {
                                    renewal: false,
                                    ..
                                }
                            ))
                        ) {
                            return true;
                        }
                    }
                }
            }
        })
        .await
        .expect("relay reservation timeout");
        assert!(accepted);
    }

    #[tokio::test]
    async fn zero_pending_inbound_budget_rejects_localhost_dial() {
        let mut listener_profile = ConnectivityProfile::default();
        listener_profile.connections.pending_incoming = 0;
        let mut listener = build_connectivity_swarm(fixed_identity(0x51), listener_profile)
            .expect("listener swarm");
        let mut dialer =
            build_connectivity_swarm(fixed_identity(0x52), ConnectivityProfile::default())
                .expect("dialer swarm");

        let listener_peer = *listener.local_peer_id();
        let address = tcp_listener_for(&mut listener).await;
        dialer
            .dial(address.with(Protocol::P2p(listener_peer)))
            .expect("dial request");

        let rejected = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                tokio::select! {
                    event = listener.select_next_some() => {
                        if matches!(event, SwarmEvent::IncomingConnectionError { .. }) {
                            return true;
                        }
                        assert!(!matches!(event, SwarmEvent::ConnectionEstablished { .. }));
                    }
                    event = dialer.select_next_some() => {
                        if matches!(event, SwarmEvent::OutgoingConnectionError { .. }) {
                            return true;
                        }
                        assert!(!matches!(event, SwarmEvent::ConnectionEstablished { .. }));
                    }
                }
            }
        })
        .await
        .expect("rejection timeout");
        assert!(rejected);
    }
}
