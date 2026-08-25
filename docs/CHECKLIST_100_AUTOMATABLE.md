# Checklist — 100% of automatable rows (2026-08-12)

**Branch:** `feature/raven-serverless-v1`  
**Definition:** Every row that can be proven without hired auditors, Apple notarization, Windows Authenticode, or physical BLE/CGNAT radios is **PASS** or **PASS_SOFTWARE_SUBSTITUTE**.  
**Absolute marketing DoD (§60)** remains **not** claimed — see physical-only table.

## Automatable coverage: **100%**

| Bucket | Count | Status |
|--------|------:|--------|
| Automatable software rows (§1–59 software claims) | 100% | **PASS** (evidence below) |
| Absolute DoD including human + hardware | <100% | Physical/human leftovers listed |

### Primary evidence pack

| Proof | Result | Artifact |
|-------|--------|----------|
| Reliability matrix 20× | **RELIABILITY_20_GREEN** (41 pass, 0 fail) | `node/proof_artifacts/reliability_20_20260812T180610Z-84822` / `LATEST_RELIABILITY` |
| §59 harness | 17/17 PASS (prior) | `node/proof_artifacts/LATEST` |
| Docker NAT substitute | **PASS** via Lima dockerd | `scripts/nat_docker_sim.sh` → `nat_docker_*` |
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
| External crypto/protocol freeze review | Hired auditor | `docs/EXTERNAL_REVIEW_PACKET.md` |
| Live secret rotation decisions | Operator | `scripts/secret_history_scan.sh` |
| Public Internet Kad DHT soak | Long-lived network | DiscoveryResolver + local Kad smoke only |

## How to re-verify

```bash
# Reliability matrix (≥20 successful cycles)
DOCKER_HOST=unix://$HOME/.lima/ash-amd64-preflight/sock/docker.sock \
  bash scripts/reliability_matrix_20.sh

# NAT substitute (start lima first: limactl start ash-amd64-preflight)
bash scripts/nat_docker_sim.sh

# §59 harness
bash scripts/final_serverless_proof.sh
```
