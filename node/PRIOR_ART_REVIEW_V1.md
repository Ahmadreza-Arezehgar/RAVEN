# Prior-art review (short) — Raven Serverless V1

**Date:** 2026-08-12  
**Purpose:** Inform ADRs; not a wire-format copy of any listed system.

| Source | Lesson applied | What we do **not** copy |
|--------|----------------|-------------------------|
| MIT DTN / store-carry-forward | Persist opaque bundles until next hop; TTL | BPv7 CBOR wire |
| Spray-and-Wait / binary spray | `replication_budget` bounds fan-out | Exact epidemic algorithms |
| RFC 9171 (BPv7) | Lifetime + hop-safety mindset | Bundle Protocol blocks |
| Signal Double Ratchet | Directional FS via ATSAM chain ratchet v2 | Full Signal protocol / Sesame |
| libp2p | Dial, identify, relay, DHT discovery patterns | Mandatory IPFS stack |
| Briar / Cwtch / Session | Offline-first, no central inbox | Their identity or onion formats |

Threat alignment: see `docs/THREAT_MODEL.md` + checklist §45 — relays are untrusted; endpoint E2EE is the boundary.
