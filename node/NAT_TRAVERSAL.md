# NAT / CGNAT traversal status (honest)

**Status:** `BLOCKED_HARDWARE` for live multi-NAT / CGNAT / DCUtR matrix.  
**Date:** 2026-08-12  
**Branch:** `feature/raven-serverless-v1`

## Not yet run

- Public-to-NAT, NAT-to-NAT, carrier-grade NAT
- AutoNAT reachability probes on real networks
- Circuit Relay v2 reservations + DCUtR hole punch
- Full `rust-libp2p` Quic+Kad swarm on the **public Internet** (localhost two-node TCP+Kad software proof: `node/scripts/libp2p_swarm_smoke.sh`)

## Software substitutes (landed)

| Substitute | Evidence |
|------------|----------|
| TCP InternetTransport hello+frame | `raven_core::internet` unit tests |
| Dial smoke | `node/scripts/internet_dial_smoke.sh` |
| LAN path | `node/scripts/lan_path_smoke.sh` |
| Signed peer discovery records | `raven_core::discovery::PeerRecord` + `DiscoveryStore` |
| Opaque store-carry when path down | `bridge_abc_demo` + `store_object` |

## Code pointers

- Spec: `protocol/RAVEN_TRANSPORT_INTERFACE_V1.md` §5–6
- Constant: `raven_core::discovery::NAT_STATUS`
