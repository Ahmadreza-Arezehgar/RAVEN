# §59 developer aggregate — automated regression harness

## What this is

`scripts/final_serverless_proof.sh` aggregates the software checks listed below
on a developer machine. Some steps intentionally use debug-only
`unsafe-demo-crypto`, mock transports, or loopback peers, so the harness must
not be described as production ATSAM or end-to-end release proof:

| §59 intent | How the harness covers it |
|---|---|
| Fresh profile / identity | Ephemeral data-dirs + `ash init` / `whoami` (not an OS installer test) |
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

`AUTOMATED_PROOF_GREEN` means only that every named harness step passed for the
recorded Git commit, source-tree state (`clean` or `dirty`), and host. A dirty
run is not reproducible from the commit alone. Always inspect the generated
per-step logs and `BLOCKED.md`; do not copy a prior local `LATEST` result to a
newer commit.

## Claim language (honest)

When green, the accurate claim is:

> **Developer aggregate checks passed** for the source state and host recorded
> in this run.

This is still **not** marketing READY / full §59 DoD, production ATSAM proof,
physical multi-device evidence, or an external audit. See each run's
`BLOCKED.md`.

## Related

- Physical 3-device BLE: `docs/PHYSICAL_BLE_THREE_DEVICE.md`
- NAT substitutes: `docs/NAT_SOFTWARE_SIM.md` + `scripts/nat_docker_sim.sh`
- External review handoff: `docs/EXTERNAL_REVIEW_PACKET.md`
