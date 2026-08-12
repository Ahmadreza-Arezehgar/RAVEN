# Prior-art review (short) — Raven Serverless V1

**Date:** 2026-08-12 (updated friend/mesh/bridge mapping)  
**Purpose:** Inform ADRs; not a wire-format copy of any listed system.  
**Design memo:** `docs/SERVERLESS_FRIEND_MESH_BRIDGE_DESIGN.md` (three planes: trust / delivery / Bridge).

| Source | Lesson applied | What we do **not** copy / claim |
|--------|----------------|----------------------------------|
| MIT DTN / store-carry-forward | Persist opaque bundles until next hop; TTL | BPv7 CBOR wire |
| Spray-and-Wait / binary spray | `replication_budget` + hop bounds fan-out | Exact epidemic algorithms; “optimal” DTN |
| Fall DTN gateway | Bridge = untrusted cross-transport custody of same envelope | Social “bridge node” / friend introducer |
| RFC 9171 (BPv7) | Lifetime + hop-safety mindset | Bundle Protocol blocks |
| BUBBLE / SimBet (Cambridge/Trinity research) | Future **optional** social-aware heuristics research | V1 product routing claims |
| PeerSoN | P2P social without ISP login as identity | PeerSoN DHT schema |
| Safebook | FOAF/privacy overlay lessons | Shipping FOAF in V1 |
| Grassroots Social Networking (arXiv:2306.13941) | Local-first social without platform sovereign | “World’s first” marketing |
| Bridgefy / BLE mesh lessons | Epidemic + abuse/privacy honesty | Military-grade claims |
| Signal Double Ratchet | Directional FS via ATSAM chain ratchet v2 | Full Signal protocol / Sesame |
| libp2p | Dial, identify, relay, DHT discovery patterns | Mandatory IPFS stack |
| Briar / Cwtch / Session | Offline-first, no central inbox | Their identity or onion formats |

## Plane mapping (law)

1. **Trust/friendship** — QR/OOB, fingerprint, signed prekey, local contacts. Never central people directory / FastAPI friendship.
2. **Delivery** — store-carry-forward opaque ciphertext (mesh/relay/Internet).
3. **Interop** — Raven Bridge = DTN-style cross-transport of the same `RavenEnvelopeV1`.

Threat alignment: see `docs/THREAT_MODEL.md` + checklist §45 — relays are untrusted; endpoint E2EE is the boundary.
