# Identity seed storage (raven-node / ash)

The Ed25519 **identity seed** for desktop `raven-node`, `ash`, and `raven-swarm` is persisted through `raven_core::identity_store`. Callers must never log, print, or put the seed in argv/env.

## Backends

| Platform | Backend | Notes |
|----------|---------|--------|
| macOS | **Keychain** (generic password, service `app.raven.node.identity`) | Account = SHA-256 of canonical `data_dir`. Marker file `identity.backend` = `macos-keychain`. |
| Windows | **DPAPI** file (`CryptProtectData`, `CRYPTPROTECT_UI_FORBIDDEN`) | Blob in `identity.seed` with magic `RVNDPAPI` + version. Bound to the Windows user. |
| Linux (glibc desktop) | **Secret Service** when session bus / collection unlock succeeds | Same service/account attributes as Keychain. |
| Linux (musl, headless, no approved Secret Service creation path) | **No Release backend** | Fresh identity creation fails closed. Locked-file mode is Debug/lab only. |

`ash doctor` reports `secure_keystore: backend=…` only (no seed bytes).

### macOS launchd continuity hold

The Keychain backend is implemented, but protected storage alone is not proof
of service continuity. `raven` and `raven-node` are separate executables, and
their final signatures/Keychain ACL behavior has not been validated on a
physical Mac under launchd. Until a test proves the same public identity before
and after service start/restart with no UI prompt or hang, the macOS source and
launchd installers and unsigned archive builder remain fail-closed by default.
The lab acknowledgement documented in
[`INSTALL_macOS.md`](INSTALL_macOS.md) does not clear this release gate.

## Legacy migration

If a legacy **plaintext** `identity.seed` (exactly 32 raw bytes, no DPAPI magic) is present:

1. Load the seed
2. Re-store via the platform backend above
3. Wipe/remove the plaintext file (macOS / Secret Service) or rewrite as DPAPI (Windows)

Migration runs automatically on first `load_identity` / `load_or_create_identity`.

## Linux Secret Service unavailable

Headless servers, containers, and **musl static** builds do not link Secret
Service (needs libdbus). Release builds do **not** fall back to a file seed:
fresh identity creation fails closed until an approved protected backend exists.

`RAVEN_IDENTITY_BACKEND=locked-file` is limited to non-Release, ephemeral
debug/CI labs. It creates a mode-`0600` seed only for those explicit labs and
must not be described, packaged, or promoted as a production keystore.

On GNU/Linux, an existing Secret Service identity can be read only after backend
continuity validation. Creation of a new protected Secret Service identity is
itself held at the reviewed R1 add-only/no-prompt gate; see
[`INSTALL_Linux.md`](INSTALL_Linux.md).

## Operator reminders

- Use ephemeral `--data-dir` for demos; never commit `identity.seed` or `identity.backend`
- `ash` still never prints private keys (public address / fingerprint / pub hex only)
- Locked / missing Keychain or Secret Service: operations that need the identity fail closed with a redacted error (no seed in the message)
