# DONE_CHECKLIST (software slice — honest)

> **Historical snapshot, not a current done/production checklist.** Statuses
> below were recorded for the 2026-08 serverless slice. The former aggregate
> proof script is absent, so its 17/17 result is archived evidence only. See
> [current verification status](FINAL_SERVERLESS_PROOF.md).

Companion to `docs/MASTER_CHECKLIST_STATUS.md`. This is **not** Final DoD §60.

## P0 Cross-device reliability

| Item | Status | Evidence |
|------|--------|----------|
| senderUserId mapping (flag ON) | ✅ software | `RavenEnvelopeSenderResolver` + Bridge publish + PeerKeyDirectory reverse |
| Endpoint ingest → sealer + Delivered | ✅ software | ChatWire + tests |
| A↔B↔C automated | ✅ | `bridge_abc_demo` + §59 harness |
| iOS hardware 3-phone | ❌ BLOCKED_HARDWARE | `docs/PHYSICAL_BLE_THREE_DEVICE.md` |

## P1 Crypto

| Item | Status | Evidence |
|------|--------|----------|
| ATSAM beyond 0x7F | ✅ subset | `atsam_root` + `atsam_kdf` + `atsam_aead` + shared vectors |
| ML-KEM full stack | ❌ gap | iOS primary; Rust known-root/X25519 |
| KATs shared | ✅ | `shared-vectors/rvn1/atsam/*` |
| External review packet | packet prepared | Input exists; independent review not completed |

## P2 Networking / services

| Item | Status | Evidence |
|------|--------|----------|
| InternetTransport endpoint delivery | ❌ PRODUCTION HOLD | `internet_dial_smoke.sh` proves exact ATSAM refusal |
| Full libp2p QUIC/DHT/DCUtR public | ❌ BLOCKED_HARDWARE | local swarm smoke green |
| Capability advertisement | 🟡 bounded | Internet only; default swarm no longer falsely advertises Relay |
| Always-on node scripts | ✅ | launchd / systemd / Windows |
| ash↔node IPC | ✅ | service survives ash exit (§59) |
| NAT docker substitute | ✅ script | SKIP when Docker down |

## P3 BLE

| Item | Status | Evidence |
|------|--------|----------|
| mock_ble CI | ✅ | bridge_abc + §59 |
| iOS GATT flagged | ✅ | BLEMeshEngine + carrier |
| raven-node CoreBluetooth | 🟡 compile seam | `--features corebluetooth`; radio BLOCKED_HARDWARE |

## P4 Packaging

| Item | Status | Evidence |
|------|--------|----------|
| Unsigned release layout | ✅ | `scripts/release/build_unsigned.sh` + SHA256 |
| INSTALL_* docs | ✅ | macOS / Linux / Windows |
| Signing/notarize | ❌ BLOCKED_HUMAN | `docs/SIGNING_NOTARIZATION_CHECKLIST.md` |

## P5 Product freeze text path

| Item | Status | Evidence |
|------|--------|----------|
| Serverless without FastAPI | ✅ | §59 harness + demos |
| Rate/TTL/hop/dedup/restart | ✅ | bridge_v1 + demos |
| §59 automated proof | historical only | Archived 2026-08-21 `AUTOMATED_PROOF_GREEN`; not rerunnable now |

## Historical “last green” record

- Former §59 harness (17/17 archived artifact; script removed)
- `cargo test -p raven-core` / `ash` / bridge_v1 / fuzz_smoke
- bridge_abc, two_node, lan, internet, swarm, mailbox, manual bootstrap

Do not infer that the listed suites are green for the current commit without
rerunning the commands in [`FINAL_SERVERLESS_PROOF.md`](FINAL_SERVERLESS_PROOF.md).

## READY FOR YOUR FULL TEST?

**NO** (marketing READY) — hardware + external review remain.  
**Current implementation/proof completeness is not asserted by this historical file.**
