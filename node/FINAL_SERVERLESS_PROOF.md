# Serverless verification status

**Current status (2026-08-30): an aggregate developer harness is present at the
repository root, but it is not a production-readiness proof.**

From the repository root, `scripts/final_serverless_proof.sh` runs a collection
of software regressions and writes ignored local output below
`node/proof_artifacts/`. The harness includes explicit debug/lab paths such as
`unsafe-demo-crypto`, mock transports, and loopback peers. A green run means
only that its named checks passed for the recorded Git SHA, source-tree state,
and host; a dirty run is not reproducible from the commit alone. It is not
production ATSAM evidence, a physical multi-device result, or an external
audit. Do not treat an old local `proof_artifacts/LATEST` pointer as evidence
for a newer commit.

No independent external protocol or cryptographic audit is recorded as
completed. The [external review packet](EXTERNAL_REVIEW_PACKET.md) is input for
a future reviewer, not an audit report.

## Current executable checks

Run these from `node/` against the exact commit being reviewed:

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo test --locked -p raven-node --test service_process
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
bash scripts/ash_listen_secure_service_smoke.sh
bash scripts/lan_direct_two_node.sh
bash scripts/bridge_abc_demo.sh
bash scripts/internet_dial_smoke.sh
```

The broader developer harness is invoked separately from the repository root:

```bash
bash scripts/final_serverless_proof.sh
```

Review its generated `BLOCKED.md` and the individual step logs, not just the
`AUTOMATED_PROOF_GREEN` marker. The harness is intentionally a debug/integration
aggregate and does not supersede the release-profile checks above.

The bridge demo verifies mutually authenticated local pull, opaque custody,
store-carry, signed custody receipts, and reverse delivery. It intentionally
compiles the `unsafe-demo-crypto` lab payload mode, so it is transport evidence,
not production ATSAM or physical-radio evidence.

The Internet smoke is a **negative security gate**: success means the legacy
raw Internet sender refused unauthenticated origination. It does not prove
Internet delivery.

The `service_process` regression launches a real daemon process, proves its
same-user IPC readiness, completes a Noise/RLB1 `LanDial` against the service
listener, and checks that the distinct authenticated bridge socket is
published and LAN-bindable. It also proves a duplicate service is refused
without orphaning the original IPC socket or replacing its bridge publication.
It does not prove automatic A→B→C route discovery; `ash send` still dials the
selected contact directly.

The `ash_listen_secure_service_smoke` gate launches `ash listen` and its real
`raven-node service` child, verifies IPC readiness, then proves a second
`ash listen` reuses that exact live service without replacing or broadly
terminating processes.

The `lan_direct_two_node` gate launches separate real profiles, pins both
address/key bindings, proves contact → authenticated send → inbox, and proves
an untrusted third profile is refused. It explicitly sets the debug-only
`RAVEN_LAB_TEST_A` origination gate, so it is integration evidence rather than
production ATSAM-bootstrap evidence.

When the GNU Windows target is installed, this compile-only check is also
available:

```bash
cargo check -p ash --target x86_64-pc-windows-gnu --offline
```

Passing these commands proves only their named scopes. They do not replace
physical multi-device tests, public CGNAT/DCUtR tests, platform signing, or an
independent security review. The root aggregate harness is a convenience runner
for developer evidence, not a one-command release acceptance gate.

## Historical artifacts

- [`proof_artifacts/README.md`](proof_artifacts/README.md) explains the ignored
  local run layout and evidence limits.
- [`MASTER_CHECKLIST_STATUS.md`](MASTER_CHECKLIST_STATUS.md) and
  [`MASTER_CHECKLIST_WALK_IN_PROGRESS.md`](MASTER_CHECKLIST_WALK_IN_PROGRESS.md)
  are dated engineering snapshots, not current acceptance reports.
- Hardware and human gates remain listed in
  [`MASTER_ENGINEERING_CHECKLIST.md`](MASTER_ENGINEERING_CHECKLIST.md).
