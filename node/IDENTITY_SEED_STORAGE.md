# Identity seed storage (raven-node / ash)

The Ed25519 **identity seed** for desktop `raven-node`, `ash`, and `raven-swarm` is persisted through `raven_core::identity_store`. Callers must never log, print, or put the seed in argv/env.

## Backends

| Platform | Backend | Notes |
|----------|---------|--------|
| macOS | **Keychain** (generic password, service `app.raven.node.identity`) | Account = SHA-256 of canonical `data_dir`. Marker file `identity.backend` = `macos-keychain`. |
| Windows | **DPAPI** file (`CryptProtectData`, `CRYPTPROTECT_UI_FORBIDDEN`) | Blob in `identity.seed` with magic `RVNDPAPI` + version. Bound to the Windows user. |
| Linux (glibc desktop) | **Secret Service** when session bus / collection unlock succeeds | Same service/account attributes as Keychain. |
| Linux (musl, headless, no Secret Service) | **Locked file** mode `0600` | **Approved** fallback — see below. |

`ash doctor` reports `secure_keystore: backend=…` only (no seed bytes).

## Legacy migration

If a legacy **plaintext** `identity.seed` (exactly 32 raw bytes, no DPAPI magic) is present:

1. Load the seed
2. Re-store via the platform backend above
3. Wipe/remove the plaintext file (macOS / Secret Service) or rewrite as DPAPI (Windows)

Migration runs automatically on first `load_identity` / `load_or_create_identity`.

## Linux Secret Service unavailable

Headless servers, containers, and **musl static** builds do not link Secret Service (needs libdbus). In those environments Raven uses a **mode `0600` locked file** under `--data-dir`. That is an intentional, checklist-approved local keystore design when Secret Service is unavailable:

- File owner read/write only
- Not world-readable
- Still protect the host user account and disk encryption; do not copy `data_dir` to untrusted machines

Prefer a graphical session with Secret Service on multi-user Linux desktops when available — new identities try Secret Service first and fall back to the locked file.

## Operator reminders

- Use ephemeral `--data-dir` for demos; never commit `identity.seed` or `identity.backend`
- `ash` still never prints private keys (public address / fingerprint / pub hex only)
- Locked / missing Keychain or Secret Service: operations that need the identity fail closed with a redacted error (no seed in the message)
