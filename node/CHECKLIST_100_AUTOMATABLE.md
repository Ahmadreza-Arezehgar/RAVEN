# Historical checklist snapshot — former “100% automatable” claim (2026-08-12)

> **Historical, not current acceptance.** The counts below were recorded on
> 2026-08-12 and have not been recomputed for the current checkout. Several
> cited aggregate scripts were later removed. Use
> [current verification status](FINAL_SERVERLESS_PROOF.md) instead of quoting
> this document as a present 100% or production-readiness result.

**Branch:** `feature/raven-serverless-v1`  
**Historical definition:** Rows believed automatable at that time were recorded as **PASS** or **PASS_SOFTWARE_SUBSTITUTE**.
**Absolute marketing DoD (§60)** remains **not** claimed — see physical-only table.

## Recorded automatable coverage: **100% (historical, not revalidated)**

| Bucket | Count | Status |
|--------|------:|--------|
| Automatable software rows (§1–59 software claims) | 100% | Historical claim; not current acceptance |
| Absolute DoD including human + hardware | <100% | Physical/human leftovers listed |

### Primary evidence pack

| Proof | Result | Artifact |
|-------|--------|----------|
| Reliability matrix 20× | **RELIABILITY_20_GREEN** | `node/proof_artifacts/reliability_20_*` / `LATEST_RELIABILITY` |
| §59 harness | Historical 17/17 snapshot (2026-08-21) | `node/proof_artifacts/LATEST`; generator removed |
| Docker NAT substitute | Historical artifact only | former generator removed; not currently reproducible from this tree |
| Linux runtime | musl `ash --help` in Lima VM | `limactl shell ash-amd64-preflight` |
| Windows | PE32+ self-check (`ash.exe`) | `PASS_SOFTWARE_SUBSTITUTE` (wine needs sudo/gstreamer) |
| iOS iPhone sim | Discovery + ContactRequest + RavenEnvelope* | `RAVEN-iPhone-15` ×2 **TEST SUCCEEDED** |
| iOS iPad sim | Same suite | `iPad Air 11-inch (M4)` ×2 **TEST SUCCEEDED** |
| macOS native | ash/raven-node demos + Keychain identity_store | primary desktop |

### Status doc mapping

See `docs/MASTER_CHECKLIST_STATUS.md` and `docs/MASTER_CHECKLIST_WALK_IN_PROGRESS.md`.  
Automatable IN_PROGRESS debt closed to **PASS / PASS (software)** where a software substitute exists; remaining **BLOCKED_*** are physical/human only.

## Physical-only / human-only (absolute DoD leftovers)

| Item | Why not automatable | Runbook |
|------|---------------------|---------|
| Physical 3-phone BLE mesh | Real radios | `docs/PHYSICAL_BLE_THREE_DEVICE.md` |
| Live CGNAT / DCUtR | Public multi-NAT | `docs/NAT_SOFTWARE_SIM.md` (Docker = substitute only) |
| Headless CoreBluetooth GATT on desktop | Hardware radio | mock_ble software path used in CI |
| Apple notarization / Developer ID | Human + Apple account | `docs/SIGNING_NOTARIZATION_CHECKLIST.md` |
| Windows Authenticode / MSI | Human + cert | `docs/INSTALL_Windows.md` |
| External crypto/protocol freeze review | Hired auditor | Packet exists; independent review is not completed |
| Live secret rotation decisions | Operator | Historical report exists; generator script is absent |
| Public Internet Kad DHT soak | Long-lived network | DiscoveryResolver + local Kad smoke only |

## How to verify the current checkout

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
bash scripts/bridge_abc_demo.sh
bash scripts/internet_dial_smoke.sh
```

These commands have narrower scopes than the historical matrix. They do not
re-establish the old 100% count. The bridge demo enables an unsafe lab payload
feature and is not production-crypto or physical-radio proof; see
[`FINAL_SERVERLESS_PROOF.md`](FINAL_SERVERLESS_PROOF.md).
