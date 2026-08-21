//! Transport kinds + path selection for Raven Bridge V1.
//!
//! Bridge = cross-transport opaque forward. Relay = same-transport.
//! Prefer MessageRouter + adapters over transport spaghetti.

use serde::{Deserialize, Serialize};

/// Carrier kind — never used as Raven identity (no BLE MAC / IP as identity).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportKind {
    Ble,
    Lan,
    Internet,
    /// In-process / test loopback mock (CI).
    MockBle,
}

impl TransportKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ble => "ble",
            Self::Lan => "lan",
            Self::Internet => "internet",
            Self::MockBle => "mock_ble",
        }
    }
}

/// Generic capability advertisement only — never “I know Bob”.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeCapability {
    Ble,
    Internet,
    Relay,
    Store,
    Bridge,
}

impl NodeCapability {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ble => "ble",
            Self::Internet => "internet",
            Self::Relay => "relay",
            Self::Store => "store",
            Self::Bridge => "bridge",
        }
    }
}

/// Path preference order (V1): local/direct → Internet direct → relay →
/// cross-carrier bridge → encrypted store-and-forward. `Unavailable` is a
/// fail-closed result, never permission to enqueue on a disabled carrier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathChoice {
    Direct,
    Internet,
    Relay,
    Bridge,
    Store,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PathContext {
    pub local_has_internet: bool,
    pub local_has_ble: bool,
    pub peer_reachable_direct: bool,
    pub peer_reachable_internet: bool,
    pub peer_reachable_ble: bool,
    pub bridge_enabled: bool,
    pub store_enabled: bool,
    pub relay_enabled: bool,
}

/// Build the ordered set of paths that are actually usable for this peer.
///
/// The caller may attempt each entry in order and stop only after a verified
/// endpoint ACK. Merely writing to one carrier is not delivery. Disabled or
/// unreachable carriers never appear in the plan.
pub fn plan_paths(ctx: &PathContext) -> Vec<PathChoice> {
    let mut paths = Vec::with_capacity(5);
    if ctx.peer_reachable_direct {
        paths.push(PathChoice::Direct);
    }
    if ctx.local_has_internet && ctx.peer_reachable_internet {
        paths.push(PathChoice::Internet);
    }
    if ctx.relay_enabled && ctx.local_has_internet {
        paths.push(PathChoice::Relay);
    }
    if ctx.bridge_enabled
        && ((ctx.local_has_internet && ctx.peer_reachable_ble)
            || (ctx.local_has_ble && ctx.peer_reachable_internet))
    {
        paths.push(PathChoice::Bridge);
    }
    if ctx.store_enabled {
        paths.push(PathChoice::Store);
    }
    paths
}

/// Select the first currently usable path. Content stays immutable; this only
/// chooses a carrier. Callers that implement retry/fallback should use
/// [`plan_paths`] rather than recomputing policy after each failure.
pub fn select_path(ctx: &PathContext) -> PathChoice {
    plan_paths(ctx)
        .into_iter()
        .next()
        .unwrap_or(PathChoice::Unavailable)
}

/// Thin legacy helper (LAN preference) — kept for existing callers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportPreference {
    DirectLan,
    InternetLibp2p,
    BleMesh,
    Unavailable,
}

pub fn prefer_transport(
    wifi_up: bool,
    peer_on_lan: bool,
    ble_peers_nearby: bool,
) -> TransportPreference {
    if wifi_up && peer_on_lan {
        TransportPreference::DirectLan
    } else if wifi_up {
        TransportPreference::InternetLibp2p
    } else if ble_peers_nearby {
        TransportPreference::BleMesh
    } else {
        TransportPreference::Unavailable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_wins() {
        let ctx = PathContext {
            local_has_internet: true,
            local_has_ble: true,
            peer_reachable_direct: true,
            peer_reachable_internet: true,
            peer_reachable_ble: true,
            bridge_enabled: true,
            store_enabled: true,
            relay_enabled: true,
        };
        assert_eq!(select_path(&ctx), PathChoice::Direct);
        assert_eq!(
            plan_paths(&ctx),
            vec![
                PathChoice::Direct,
                PathChoice::Internet,
                PathChoice::Relay,
                PathChoice::Bridge,
                PathChoice::Store,
            ]
        );
    }

    #[test]
    fn bridge_when_cross_radio() {
        let ctx = PathContext {
            local_has_internet: true,
            local_has_ble: true,
            peer_reachable_direct: false,
            peer_reachable_internet: false,
            peer_reachable_ble: true,
            bridge_enabled: true,
            store_enabled: true,
            relay_enabled: false,
        };
        assert_eq!(select_path(&ctx), PathChoice::Bridge);
    }

    #[test]
    fn store_when_nothing_else() {
        let ctx = PathContext {
            local_has_internet: false,
            local_has_ble: false,
            peer_reachable_direct: false,
            peer_reachable_internet: false,
            peer_reachable_ble: false,
            bridge_enabled: false,
            store_enabled: true,
            relay_enabled: false,
        };
        assert_eq!(select_path(&ctx), PathChoice::Store);
    }

    #[test]
    fn disabled_carriers_never_create_a_phantom_route() {
        let ctx = PathContext {
            local_has_internet: false,
            local_has_ble: false,
            peer_reachable_direct: false,
            peer_reachable_internet: false,
            peer_reachable_ble: false,
            bridge_enabled: false,
            store_enabled: false,
            relay_enabled: false,
        };
        assert!(plan_paths(&ctx).is_empty());
        assert_eq!(select_path(&ctx), PathChoice::Unavailable);
        assert_eq!(
            prefer_transport(false, false, false),
            TransportPreference::Unavailable
        );
    }

    #[test]
    fn relay_and_store_are_ordered_fallbacks_not_delivery_claims() {
        let ctx = PathContext {
            local_has_internet: true,
            local_has_ble: false,
            peer_reachable_direct: false,
            peer_reachable_internet: false,
            peer_reachable_ble: false,
            bridge_enabled: false,
            store_enabled: true,
            relay_enabled: true,
        };
        assert_eq!(plan_paths(&ctx), vec![PathChoice::Relay, PathChoice::Store]);
        assert_eq!(select_path(&ctx), PathChoice::Relay);
    }

    #[test]
    fn local_radios_alone_do_not_invent_a_bridge_route_to_the_peer() {
        let ctx = PathContext {
            local_has_internet: true,
            local_has_ble: true,
            peer_reachable_direct: false,
            peer_reachable_internet: false,
            peer_reachable_ble: false,
            bridge_enabled: true,
            store_enabled: false,
            relay_enabled: false,
        };
        assert!(plan_paths(&ctx).is_empty());
        assert_eq!(select_path(&ctx), PathChoice::Unavailable);
    }

    #[test]
    fn lan_wins_when_both() {
        assert_eq!(
            prefer_transport(true, true, true),
            TransportPreference::DirectLan
        );
    }

    #[test]
    fn ble_when_offline() {
        assert_eq!(
            prefer_transport(false, false, true),
            TransportPreference::BleMesh
        );
    }
}
