# NAT / CGNAT traversal status (honest)

**Status:** `BLOCKED_HARDWARE` for live multi-NAT / CGNAT / DCUtR matrix.  
**Date:** 2026-08-13

## Not yet run

- Public-to-NAT, NAT-to-NAT, carrier-grade NAT
- AutoNAT reachability probes on real networks
- Circuit Relay v2 reservations + DCUtR hole punch across independently
  operated public relays (the client composition is implemented but not a
  hardware result)
- Full `rust-libp2p` QUIC+Kademlia swarm on the **public Internet** (localhost
  two-node software proofs are not equivalent)

## Software substitutes (landed)

| Substitute | Evidence |
|------------|----------|
| TCP InternetTransport hello+frame | `raven_core::internet` unit tests |
| Raw Internet message hold | `node/scripts/internet_dial_smoke.sh` (negative gate) |
| LAN path | `node/scripts/lan_path_smoke.sh` |
| Signed peer discovery records | `raven_core::discovery::PeerRecord` + `DiscoveryStore` |
| Opaque store-carry when path down | `bridge_abc_demo` + `store_object` |
| Bounded NAT client composition | gated `raven-swarm::connectivity`: TCP/QUIC, Noise/Yamux, AutoNAT v2 client, Relay v2 client, DCUtR, connection limits |
| Authenticated localhost transports | real fixed-node TCP+Noise and QUIC integration tests |
| Admission refusal | zero-pending-inbound integration test rejects before establishment |

## Code pointers

- Spec: `protocol/RAVEN_TRANSPORT_INTERFACE_V1.md` §5–6
- Experimental profile: `protocol/RAVEN_NAT_CONNECTIVITY_V1.md`
- Constant: `raven_core::discovery::NAT_STATUS`


## Expanded substitutes (REST wave)

| Substitute | Evidence |
|------------|----------|
| Docker dual-network isolation | Historical archived result; its generator is absent from the current tree |
| Docs | Historical design notes in `docs/NAT_SOFTWARE_SIM.md` |
| Current checks | `cargo test -p raven-core` plus `scripts/internet_dial_smoke.sh` (negative fail-closed gate only) |

The archived §59 17/17 run is not current NAT evidence. See
[`FINAL_SERVERLESS_PROOF.md`](FINAL_SERVERLESS_PROOF.md). None of these software
checks establishes live CGNAT/DCUtR interoperability.
