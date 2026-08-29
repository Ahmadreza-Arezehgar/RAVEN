# Serverless verification status

**Current status (2026-08-29): no aggregate production-proof harness is present in this tree.**

The former `scripts/final_serverless_proof.sh` is not included in the current
checkout. The committed [`proof_artifacts/LATEST`](proof_artifacts/LATEST)
snapshot records a 17/17 run from 2026-08-21, but that is historical evidence
for an older tree. It cannot be rerun here and must not be presented as a
current `AUTOMATED_PROOF_GREEN`, production-readiness result, or external audit.

No independent external protocol or cryptographic audit is recorded as
completed. The [external review packet](EXTERNAL_REVIEW_PACKET.md) is input for
a future reviewer, not an audit report.

## Current executable checks

Run these from `node/` against the exact commit being reviewed:

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
bash scripts/bridge_abc_demo.sh
bash scripts/internet_dial_smoke.sh
```

The bridge demo verifies mutually authenticated local pull, opaque custody,
store-carry, signed custody receipts, and reverse delivery. It intentionally
compiles the `unsafe-demo-crypto` lab payload mode, so it is transport evidence,
not production ATSAM or physical-radio evidence.

The Internet smoke is a **negative security gate**: success means the legacy
raw Internet sender refused unauthenticated origination. It does not prove
Internet delivery.

When the GNU Windows target is installed, this compile-only check is also
available:

```bash
cargo check -p ash --target x86_64-pc-windows-gnu --offline
```

Passing these commands proves only their named scopes. They do not replace
physical multi-device tests, public CGNAT/DCUtR tests, platform signing, or an
independent security review. There is currently no supported one-command
replacement for the removed §59 harness.

## Historical artifacts

- [`proof_artifacts/README.md`](proof_artifacts/README.md) explains the archived
  run layout.
- [`MASTER_CHECKLIST_STATUS.md`](MASTER_CHECKLIST_STATUS.md) and
  [`MASTER_CHECKLIST_WALK_IN_PROGRESS.md`](MASTER_CHECKLIST_WALK_IN_PROGRESS.md)
  are dated engineering snapshots, not current acceptance reports.
- Hardware and human gates remain listed in
  [`MASTER_ENGINEERING_CHECKLIST.md`](MASTER_ENGINEERING_CHECKLIST.md).
