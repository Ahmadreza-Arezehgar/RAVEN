# Install Raven Serverless (Windows)

Also see [`node/WINDOWS.md`](../node/WINDOWS.md) and [`node/scripts/install/WINDOWS_SERVICE.md`](../node/scripts/install/WINDOWS_SERVICE.md).

## Native build

```powershell
cd node
cargo build -p raven-core -p raven-node -p ash --release
.\target\release\ash.exe --data-dir $env:TEMP\raven-data init
.\target\release\ash.exe --data-dir $env:TEMP\raven-data doctor
```

The GitHub Windows workflow packages `raven.exe`, `ash.exe`, and
`raven-node.exe`. It fails closed unless pinned `cargo-about 0.9.1` generates
`THIRD_PARTY_LICENSES_AND_NOTICES.txt`, and its checksum manifest covers that
bundle as well as every other packaged file. The unsigned artifact does not
replace native two-profile transport validation.

Task Scheduler / service helper: `scripts/install/windows_service.ps1`.
The held helper keeps installer metadata outside the identity profile and runs
`raven init` before task registration/start; those ordering checks do not clear
the outstanding native two-profile gate.

## Unsigned layout from macOS/Linux host

Cross-compile notes in `node/WINDOWS.md`. Prefer native Windows CI for release binaries you will Authenticode-sign.

## Signing

MSI / Authenticode steps: [`SIGNING_NOTARIZATION_CHECKLIST.md`](SIGNING_NOTARIZATION_CHECKLIST.md). This repo ships **unsigned** artifacts only.

## Identity seed

Windows stores the node seed as a **DPAPI**-protected `identity.seed` blob (user-bound). Legacy plaintext 32-byte files are migrated automatically. See [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).
