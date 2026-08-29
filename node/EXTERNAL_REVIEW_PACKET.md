# External Review Packet — Raven Serverless V1

**Purpose:** Hand this directory of pointers to an independent protocol/crypto reviewer.  
**Branch:** `feature/raven-serverless-v1`  
**Status:** Review-input draft; no completed independent protocol or cryptographic audit is recorded.
**Not claimed:** Production readiness, full §59/§60 DoD, notarization, live CGNAT, or a physical BLE radio matrix.

The old 17/17 §59 artifact is a historical 2026-08-21 snapshot whose generator
is no longer present. See [current verification status](FINAL_SERVERLESS_PROOF.md).

---

## 1. Threat model

| Doc | Role |
|---|---|
| [`docs/THREAT_MODEL.md`](../docs/THREAT_MODEL.md) | Serverless P2P threat model (Phase A) — 17 adversary classes |
| [`docs/AUDIT_SERVERLESS_PIVOT_2026-08-12.md`](../docs/AUDIT_SERVERLESS_PIVOT_2026-08-12.md) | Internal pivot notes; not an external audit |
| [`docs/SERVERLESS_MODEL.md`](SERVERLESS_MODEL.md) | Exact meaning of “serverless” (three planes) |

Reviewer should mark any row where shipped code diverges from a cited mechanism.

---

## 2. Protocol freeze — file list + hashes

The committed [`PROTOCOL_FREEZE_HASHES_V1.md`](PROTOCOL_FREEZE_HASHES_V1.md)
was generated on 2026-08-12 for commit `7acbef7`. Its generator script is not
present, so it is a historical manifest, not proof that current files remain
frozen. A reviewer must generate and retain a fresh manifest with independent
tooling for the exact reviewed commit.

Normative specs live under `protocol/`:

| Spec | Topic |
|---|---|
| `RAVEN_IDENTITY_V1.md` | Ed25519 identity |
| `RAVEN_ADDRESS_V1.md` | Bech32m `rvn` addresses |
| `RAVEN_ENVELOPE_V1.md` | Canonical wire object |
| `RAVEN_ACK_V1.md` | Delivery ACK |
| `RAVEN_ALIAS_V1.md` / Soft Unique Tags (`docs/RAVEN_TAG_V1.md`) | Human labels |
| `RAVEN_ROUTING_TAG_V1.md` | Opaque store tags |
| `RAVEN_STORE_OBJECT_V1.md` | Store-and-forward object |
| `RAVEN_BRIDGE_V1.md` | DTN bridge (opaque) |
| `RAVEN_BLE_FRAMING_V1.md` | BLE frame |
| `RAVEN_TRANSPORT_INTERFACE_V1.md` | Transport adapters / NAT notes |
| `RAVEN_PREKEY_BUNDLE_V1.md` | Async first contact |
| `RAVEN_CAPABILITIES_V1.md` | Capability bits |
| `RAVEN_DELIVERY_STATE_V1.md` | Queue states |
| `RAVEN_ERROR_CODES_V1.md` | Errors |
| `ATSAM_PRIMITIVE_MAPPING_V1.md` | Crypto mapping |
| `RAVEN_INTEROPERABILITY_MATRIX.md` | Cross-platform |

Byte-exact fixtures: `shared-vectors/rvn1/**`.

---

## 3. Cryptographic mapping

Primary map: [`protocol/ATSAM_PRIMITIVE_MAPPING_V1.md`](../protocol/ATSAM_PRIMITIVE_MAPPING_V1.md)

| Layer | Primitive | Impl |
|---|---|---|
| Envelope auth | Ed25519 | `raven_core::envelope`, Swift `MeshCryptoService` |
| Address | SHA-256[:20] → Bech32m | `raven_core::address` |
| Routing tag | HMAC-SHA256 | `raven_core::routing_tag` |
| Message seal RVNA1 | ChaCha20-Poly1305 | iOS ATSAM + Rust `seal` |
| Hybrid root | X25519 ‖ ML-KEM-768 | `atsam_mlkem` + Swift hybrid pairing |
| Chain ratchet | HKDF-SHA256 | iOS `ATSAMChainRatchet` |

Known gaps called out in the mapping doc (PLACEHOLDER KATs, CryptoKit CT interop).

---

## 4. How to run vectors

```bash
# Python reference
(cd ../protocol/reference && python -m pytest -q)

# Rust
cargo test -p raven-core
cargo test -p raven-core --test bridge_v1 --test fuzz_smoke

# Shared vector sync (if tooling present)
# see protocol/reference + shared-vectors/README.md
```

---

## 5. Current software checks

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
bash scripts/bridge_abc_demo.sh
bash scripts/internet_dial_smoke.sh
```

These are separate scoped checks, not an aggregate proof. The Internet smoke
proves a fail-closed hold, not successful Internet messaging. The bridge demo
uses an explicitly unsafe lab payload feature and proves its authenticated
transport/custody flow rather than production ATSAM or physical radios. See
[`FINAL_SERVERLESS_PROOF.md`](FINAL_SERVERLESS_PROOF.md) for limitations.

---

## 6. Known gaps (honest)

### BLOCKED_HUMAN
- Independent freeze/crypto review (this packet)
- Apple / Windows signing & notarization
- Credential rotation decisions from `docs/SECRET_HISTORY_SCAN_REPORT.md`

### BLOCKED_HARDWARE
- Physical 3-phone BLE (`docs/PHYSICAL_BLE_THREE_DEVICE.md`)
- Public Internet Kad / CGNAT / DCUtR (`docs/NAT_SOFTWARE_SIM.md`)
- Headless CoreBluetooth radio (`raven-node --features corebluetooth` is a compile seam only)

### Software gaps / partials
- Long fuzz campaigns beyond `fuzz_smoke`
- Full ML-KEM CT interop KATs with CryptoKit
- MSI installer (unsigned layout exists; store packaging open)

---

## 7. Reviewer checklist (suggested)

1. Generate fresh hashes independently for the reviewed commit; compare the dated manifest only as historical context.
2. Walk threat-model table; spot-check citations against code.
3. Run Python + Rust vector suites; attach logs.
4. Run the current bridge/core tests and inspect their exact commit; use archived §59 transcripts only as historical context.
5. File findings against branch tip SHA (local; may be unpublished).
