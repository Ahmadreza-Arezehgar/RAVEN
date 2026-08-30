# Install Raven Serverless (Windows)

Also see [`WINDOWS.md`](WINDOWS.md) and the
[`Windows service guide`](scripts/install/WINDOWS_SERVICE.md).

## Current status: local transport implemented; native E2E pending

Windows builds, the DPAPI-protected identity lifecycle, and the same-user named-pipe `LanDial` transport are implemented. The pipe is per-profile, current-user-only, remote-client-disabled, and mutually checks the peer process SID and Windows session before accepting any frame.

Do not yet present the current `.exe` files or scheduled development service as
a complete Windows release. The remaining transport gate is execution on a
real Windows host: two independent profiles must complete PairInit, an indexed
message, and an authenticated ACK through the native pipe and LAN-direct path.
Cross-compilation alone is not that proof.

## Native build

```powershell
cd node
cargo build --locked -p raven-core -p raven-node -p ash --release
.\target\release\ash.exe --data-dir $env:TEMP\raven-data init
.\target\release\ash.exe --data-dir $env:TEMP\raven-data doctor
```

GitHub Actions workflow `build-raven-windows.yml` publishes the same supported
Rust entry points as a checksummed `raven-terminal-windows-<arch>` artifact:
`raven.exe`, `ash.exe`, and `raven-node.exe`. Pushes and pull requests build
`x64`; a manual dispatch may explicitly select `x64` or `arm64`. The artifact
is unsigned and does not represent completion of the physical E2E gate above.
Packaging fails unless pinned `cargo-about 0.9.1` generates a non-empty
`THIRD_PARTY_LICENSES_AND_NOTICES.txt`; that file and all other package files
are covered by `SHA256SUMS.txt`.

Run the complete foreground service, then verify local authorization from a
second PowerShell window:

```powershell
$Data = Join-Path $env:LOCALAPPDATA "RavenNode\data"
.\target\release\raven-node.exe service --data-dir $Data `
  --lan-listen 0.0.0.0:7420 --bridge-listen 0.0.0.0:7422 `
  --ble-listen 127.0.0.1:0
.\target\release\ash.exe --data-dir $Data ipc-ping
```

Task Scheduler / service helper: `scripts/install/windows_service.ps1`.

That helper remains disabled by default. With
`-AllowExperimentalBridgeHarness`, it installs the complete combined
development `service` command, but it does not perform or replace the required
native two-profile release validation. It keeps locks/rollback backups in the
separate per-user `RavenNode\installer-state` directory, verifies that a fresh
`RavenNode\data` profile is still empty, and runs `raven init` before registering
or starting the task.

## Unsigned layout from macOS/Linux host

Cross-compile notes in `node/WINDOWS.md`. Prefer native Windows CI for release binaries you will Authenticode-sign.

## Signing

MSI / Authenticode steps: [`SIGNING_NOTARIZATION_CHECKLIST.md`](SIGNING_NOTARIZATION_CHECKLIST.md). This repo ships **unsigned** artifacts only.

## Identity seed

Windows stores the node seed as a **DPAPI**-protected `identity.seed` blob (user-bound). Legacy plaintext 32-byte files are migrated automatically. See [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).
