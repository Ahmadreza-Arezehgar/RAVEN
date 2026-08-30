# Install Raven Serverless (macOS)

**Release hold.** Notarization requires your Apple Developer ID, but signing
alone does not clear the identity-continuity gate described below. See
[`SIGNING_NOTARIZATION_CHECKLIST.md`](SIGNING_NOTARIZATION_CHECKLIST.md).

## Current status: launchd / Keychain handoff not validated

`raven` and `raven-node` are separate executables. The login Keychain can apply
per-binary ACL/signing decisions, and this tree does not yet contain physical,
signed-Mac proof that an identity created by `raven` is read by `raven-node`
under launchd without a UI prompt, hang, or second identity. The launchd
installer and macOS archive builder therefore exit before installation or
packaging by default.

## Option A — from source

```bash
cd node
cargo build --locked -p raven-node -p ash --release
bash scripts/install/macos_launchd.sh  # expected: fail closed at the handoff gate
```

The installer performs no build, directory creation, binary replacement, plist
write, or `launchctl` operation before that refusal. An explicitly unsafe,
review-only run on an isolated disposable account is possible, but it may hang
on Keychain UI or observe a different identity:

```bash
RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK \
  bash scripts/install/macos_launchd.sh
```

Do not use that override for distribution or an always-on service. Never
overwrite `/bin/ash`; if the held installer is eventually cleared, it only
creates a user-prefix `~/.local/bin/ash` link when that path is unused.
In the review-only path, install locks and rollback backups live outside the
identity profile under `~/Library/Caches/com.raven.raven-node-installer`; the
installer verifies a fresh data directory is still empty immediately before
running `raven init`.

The inspected source installer defaults to `main`. To test an explicit remote
branch or tag in a separate checkout, set both the ref and destination; the
installer resolves it and detaches at the exact fetched commit. This path is
also held by default because it builds/links both separate Release executables.
The same unsafe lab acknowledgement is required, and success is explicitly
review-only:

```bash
RAVEN_INSTALL_REF=feature/raven-serverless-v1 \
RAVEN_DIR="$HOME/RAVEN-feature-test" \
RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK \
bash node/scripts/install.sh
```

## Option B — unsigned release tarball

```bash
RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK \
  bash scripts/release/build_unsigned.sh
# → dist/raven-serverless-*-darwin-*.tar.gz
tar xzf dist/raven-serverless-*.tar.gz
cd raven-serverless-*/
```

This produces a deterministic **review-only** archive; it is not an installable
macOS release. The builder also requires exactly `cargo-about 0.9.1` and fails
closed unless it can generate `THIRD_PARTY_LICENSES_AND_NOTICES.txt` from the
locked target dependency graph:

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
cargo clippy --locked -p raven-core -p raven-node -p ash -p raven-swarm --all-targets -- -D warnings
```

The repository-root `scripts/final_serverless_proof.sh` is a debug/developer
aggregate, not a production-proof script. In a source checkout, see
`node/FINAL_SERVERLESS_PROOF.md` for its exact scope and the remaining release,
human, and hardware gates. The aggregate harness is not included in an unsigned
binary archive.

## Identity seed

macOS stores the node seed in the **login Keychain** (service
`app.raven.node.identity`). That protected backend exists, but cross-executable
launchd continuity is the unresolved gate above. Legacy plaintext
`identity.seed` files are migrated and removed on first load. See
[`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).
