# Final Serverless Proof (§59) — automated harness

## What this is

`scripts/final_serverless_proof.sh` exercises every **software-automatable** step of the Master Checklist §59 Final Serverless Proof on a developer machine:

| §59 intent | How the harness covers it |
|---|---|
| Fresh install / identity | Ephemeral data-dirs + `ash init` / `whoami` |
| Contact add + verify | `ash contact add --verify-fp` + `contact verify` |
| Offline recipient | Bridge store-carry while mobile offline, then join |
| Encrypted locally / queue | Sealed send; bridge logs must not contain plaintext |
| No central API | `doctor` messaging_path + grep refuse FastAPI |
| Store-forward | Bridge B queues until C appears |
| Close Terminal; node continues | `raven-node service` + `ash ipc-ping` after ash exit |
| ACK / Delivered | Direct + bridged ACK logs |
| Bridge A↔B↔C both ways | `bridge_abc_demo.sh` (happy + reverse + store-carry) |
| No duplicates | `cargo test -p raven-core --test bridge_v1` |
| Shut Raven bootstrap; manual peers | `disable-raven-defaults` + `bootstrap_manual_peer_smoke` + swarm |
| Same message identity | mid logged across A/B/C in bridge demo |

## Run

```bash
bash scripts/final_serverless_proof.sh
# artifacts → node/proof_artifacts/<run-id>/
cat node/proof_artifacts/LATEST/SUMMARY.md
```

Re-run until `SUMMARY.md` says `AUTOMATED_PROOF_GREEN`.

## Claim language (honest)

When green:

> **IMPLEMENTATION + PROOF HARNESS COMPLETE** for automatable §59 software steps.

Still **not** marketing READY / full §59 DoD. See each run’s `BLOCKED.md`.

## Related

- Physical 3-device BLE: `docs/PHYSICAL_BLE_THREE_DEVICE.md`
- NAT substitutes: `docs/NAT_SOFTWARE_SIM.md` + `scripts/nat_docker_sim.sh`
- External review handoff: `docs/EXTERNAL_REVIEW_PACKET.md`
