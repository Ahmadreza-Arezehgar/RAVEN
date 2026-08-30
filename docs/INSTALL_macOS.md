# Install Raven Serverless (macOS)

**Release hold.** The canonical current guide is
[`node/INSTALL_macOS.md`](../node/INSTALL_macOS.md). Notarization alone does not
clear the identity-continuity gate below.

## Current status: launchd / Keychain handoff not validated

`raven` and `raven-node` are separate executables. There is not yet signed,
physical-Mac proof that the login Keychain allows the launchd process to reuse
the terminal-created identity without a UI prompt, hang, or identity split.
The source installer, launchd installer, and archive builder therefore fail
closed by default. `node/scripts/install.sh` refuses before clone/build/link;
`node/scripts/install/macos_launchd.sh` refuses before any install mutation.

## Option A — from source

```bash
cd node
cargo build --locked -p raven-node -p ash --release
bash scripts/install/macos_launchd.sh  # expected: refusal before any mutation
```

For an isolated disposable lab only (not distribution), the exact unsafe
acknowledgement is:

```bash
RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK \
  bash scripts/install/macos_launchd.sh
```

The override may hang on Keychain UI or observe a different identity. Never
overwrite `/bin/ash`. Installer lock/rollback state remains outside the Raven
identity profile, and a fresh profile must still be empty immediately before
`raven init`.

## Option B — unsigned release tarball

```bash
RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK \
  bash scripts/release/build_unsigned.sh
# → dist/raven-serverless-*-darwin-*.tar.gz
tar xzf dist/raven-serverless-*.tar.gz
cd raven-serverless-*/
```

The result is review-only and must not be installed/distributed as a service.
Install the pinned license generator before building:

```bash
cargo install --locked --features cli --version 0.9.1 cargo-about
```

Verify:

```bash
shasum -a 256 -c SHA256SUMS.txt
test -s THIRD_PARTY_LICENSES_AND_NOTICES.txt
```

## Gatekeeper note

Unsigned binaries will be quarantined if downloaded from the Internet. Either:
- build from source locally, or
- complete Developer ID + notarization (checklist), or
- (dev only) remove quarantine: `xattr -dr com.apple.quarantine ./bin`

## Verification

```bash
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
```

## Identity seed

macOS stores the node seed in the **login Keychain** (service
`app.raven.node.identity`). The backend exists, but cross-executable launchd
continuity remains held. Legacy plaintext `identity.seed` files are migrated
and removed on first load. See
[`node/IDENTITY_SEED_STORAGE.md`](../node/IDENTITY_SEED_STORAGE.md).
