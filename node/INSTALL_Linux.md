# Install Raven Serverless (Linux)

## Current status: R1 security hold

Fresh Linux Release installation is intentionally blocked. The production-facing identity store can read an existing GNU/Linux Secret Service identity, but creation of a new protected identity is disabled until the reviewed add-only, prompt-free R1 backend and provider content-type policy are approved.

Raven does **not** fall back to a plaintext seed or the debug-only locked-file backend in Release. Consequently, `scripts/install.sh`, `scripts/install/linux_systemd_user.sh`, and the unsigned archive builder must not be presented as working fresh-install paths on Linux yet.

## Build and test from source

```bash
cd node
cargo build --locked -p raven-node -p ash --release
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
```

The release binaries build, but a fresh `raven init` will fail closed at the protected identity-store gate. Existing profiles whose identity is already present in Secret Service may still load after continuity validation.

## Review-only unsigned archive

```bash
cargo install --locked --features cli --version 0.9.1 cargo-about
RAVEN_ALLOW_BLOCKED_LINUX_PACKAGE=1 bash scripts/release/build_unsigned.sh
```

This override produces a build-review artifact only. It does not bypass the
identity hold and must not be distributed as an installable Linux release. The
builder also fails closed unless it can generate the target dependency bundle
`THIRD_PARTY_LICENSES_AND_NOTICES.txt` with exactly `cargo-about 0.9.1`.

## Exit criteria

- Integrate the frozen add-only/no-prompt Secret Service API only after R1 authorization.
- Prove create/readback, duplicate refusal, locked-provider behavior, migration, crash continuity, and provider content-type normalization on native GNU/Linux.
- Re-enable installer/systemd/archive flows only after those gates pass.

See [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md) and `scripts/linux_secret_service_r0_hard_stop.sh` for the current boundary and evidence.
