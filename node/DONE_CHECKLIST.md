# DONE_CHECKLIST (software slice — honest)

Companion to `docs/MASTER_CHECKLIST_STATUS.md`. This is **not** Final DoD §60.

## P0 Cross-device reliability

| Item | Status | Evidence |
|------|--------|----------|
| senderUserId mapping (flag ON) | ✅ software | `RavenEnvelopeSenderResolver` + Bridge publish + PeerKeyDirectory reverse |
| Endpoint ingest → sealer + Delivered | ✅ software | ChatWire + tests |
| A↔B↔C automated | ✅ | `bridge_abc_demo` happy + store-carry + reverse |
| iOS hardware 3-phone | ❌ BLOCKED_HUMAN | simulator decision tests only |

## P1 Crypto

| Item | Status | Evidence |
|------|--------|----------|
| ATSAM beyond 0x7F | ✅ subset | `atsam_root` + `atsam_kdf` + `atsam_aead` + shared vectors |
| ML-KEM full stack | ❌ gap | iOS primary; Rust known-root/X25519 |
| KATs shared | ✅ | `shared-vectors/rvn1/atsam/*` |

## P2 Networking / services

| Item | Status | Evidence |
|------|--------|----------|
| InternetTransport dial | ✅ TCP path | `internet.rs` + `internet_dial_smoke.sh` (no FastAPI) |
| Full libp2p QUIC/DHT/DCUtR | ❌ | ADR-0002 target |
| Capability advertisement | ✅ | hello caps + node_policy caps |
| Always-on node scripts | ✅ | launchd / systemd user / Windows notes |
| ash↔node IPC | ✅ framing | `ipc.rs`; UDS live bind still thin |

## P3 BLE

| Item | Status | Evidence |
|------|--------|----------|
| mock_ble CI | ✅ | bridge_abc |
| iOS GATT flagged | ✅ | BLEMeshEngine + carrier |
| raven-node CoreBluetooth | ❌ documented substitute | iOS-as-B |

## P4 Packaging

| Item | Status | Evidence |
|------|--------|----------|
| Windows.md + ash.exe name | ✅ docs | cross-compile notes |
| Linux build in this env | ✅ | cargo on macOS host; Linux script present |
| Install local-only | ✅ | no GitHub publish |

## P5 Product freeze text path

| Item | Status | Evidence |
|------|--------|----------|
| Serverless without FastAPI | ✅ | dial/bridge demos |
| Rate/TTL/hop/dedup/restart | ✅ | bridge_v1 + demos |
| Docs + this checklist | ✅ | |

## Suites last green (this machine)

- `cargo test -p raven-core` (lib+integration)
- `cargo test -p ash`
- `bridge_v1`, `two_node`, `lan_path_smoke`, `internet_dial_smoke`, `bridge_abc`

## READY FOR YOUR FULL TEST?

**NO** — Final §59/§60 and Phase D–G gates not fully met (see MASTER_CHECKLIST_STATUS).
