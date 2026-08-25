# Install Raven Serverless (Linux)

## From source

```bash
cd node
cargo build -p raven-node -p ash --release
bash scripts/install/linux_systemd_user.sh
export PATH="$HOME/.local/bin:$PATH"
ash init
ash doctor
```

User systemd unit runs `raven-node service` (bridge + IPC). Does not require root.

## Unsigned tarball

```bash
bash scripts/release/build_unsigned.sh
tar xzf dist/raven-serverless-*-linux-*.tar.gz
cd raven-serverless-*/
./bin/ash --data-dir ./raven-data init
```

Verify `SHA256SUMS.txt`. Signing/packages (deb/rpm) are operator-owned — not produced unsigned.

## Notes

- Prefer `raven` argv0 if distribution `ash` conflicts with BusyBox `/bin/ash`.
- No central message server is configured; see `SERVERLESS_MODEL.md`.
- Identity seed storage: Secret Service when available, else mode `0600` locked file — see [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).
