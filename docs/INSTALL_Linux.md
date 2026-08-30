# Install Raven Serverless (Linux)

## Current status

The canonical current guide is
[`node/INSTALL_Linux.md`](../node/INSTALL_Linux.md). Fresh Release installation
is held at the protected identity-store gate; there is no Release fallback to a
plaintext or debug locked-file seed.

## Build from source

```bash
cd node
cargo build --locked -p raven-node -p ash --release
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
```

The binaries build, but fresh identity creation fails closed until the R1
protected-store gate is approved.

## Unsigned tarball

```bash
cargo install --locked --features cli --version 0.9.1 cargo-about
RAVEN_ALLOW_BLOCKED_LINUX_PACKAGE=1 bash scripts/release/build_unsigned.sh
tar xzf dist/raven-serverless-*-linux-*.tar.gz
cd raven-serverless-*/
```

This is a review-only archive, not an installable Linux release. Verify
`SHA256SUMS.txt` and `THIRD_PARTY_LICENSES_AND_NOTICES.txt`.

## Notes

- Prefer `raven` argv0 if distribution `ash` conflicts with BusyBox `/bin/ash`.
- No central message server is configured; see `SERVERLESS_MODEL.md`.
- Identity seed storage and the current hold are documented in
  [`node/IDENTITY_SEED_STORAGE.md`](../node/IDENTITY_SEED_STORAGE.md).
