# Install Raven Serverless (macOS)

**Unsigned developer layout.** Notarization requires your Apple Developer ID — see [`SIGNING_NOTARIZATION_CHECKLIST.md`](SIGNING_NOTARIZATION_CHECKLIST.md).

## Option A — from source

```bash
cd node
cargo build --locked -p raven-node -p ash --release
bash scripts/install/macos_launchd.sh
# ash/raven → ~/.local/bin ; raven-node launchd agent
export PATH="$HOME/.local/bin:$PATH"
ash init
ash doctor
```

Never overwrite `/bin/ash`. The installer links `~/.local/bin/ash` → `raven` only in the user prefix.

## Option B — unsigned release tarball

```bash
bash scripts/release/build_unsigned.sh
# → dist/raven-serverless-*-darwin-*.tar.gz
tar xzf dist/raven-serverless-*.tar.gz
cd raven-serverless-*/
./bin/ash --data-dir ./raven-data init
./bin/raven-node service --data-dir ./raven-data
```

Verify:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Gatekeeper note

Unsigned binaries will be quarantined if downloaded from the Internet. Either:
- build from source locally, or
- complete Developer ID + notarization (checklist), or
- (dev only) remove quarantine: `xattr -dr com.apple.quarantine ./bin`

## Verification

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
```

There is no aggregate production-proof script in the current tree. See
[`FINAL_SERVERLESS_PROOF.md`](FINAL_SERVERLESS_PROOF.md) for the exact scope and
remaining human/hardware gates.

## Identity seed

macOS stores the node seed in the **login Keychain** (service `app.raven.node.identity`). Legacy plaintext `identity.seed` files are migrated and removed on first load. See [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).
