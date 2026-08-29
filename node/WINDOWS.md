# Building `ash` + `raven-node` on Windows

Product CLI binary is named **`ash`** (`ash.exe` on Windows). Daemon/node binary is **`raven-node`** (`raven-node.exe`).  
This is **not** the WinUI `RAVEN-Windows` app; that mesh client lives under `RAVEN-Windows/` and has its own workflow.

> **Validation hold:** secure terminal send now has native Windows named-pipe
> `LanDial` IPC, but the release gate still requires a real two-profile Windows
> PairInit/indexed-message/authenticated-ACK run. Cross-compilation proves the
> Windows code is type-correct; it does not replace that native execution. The
> legacy raw/demo send path remains forbidden.

**Safety:** demos use ephemeral `--data-dir` only. Never commit `identity.seed`, queue DBs, or paste private keys into logs. On Windows the seed file is DPAPI-wrapped (`RVNDPAPI` magic); see [`IDENTITY_SEED_STORAGE.md`](IDENTITY_SEED_STORAGE.md).

## Native Windows (recommended)

### Prerequisites

- [Rust](https://rustup.rs/) stable (MSVC toolchain)
- Visual Studio Build Tools 2022 with “Desktop development with C++”
- Git

`rusqlite` is built with the `bundled` feature — no system SQLite install required.

### Build

```powershell
cd path\to\hybrid_messenger\node
cargo build -p raven-core -p raven-node -p ash --release
```

Binaries land at:

```
target\release\ash.exe
target\release\raven-node.exe
```

Smoke (public bits only):

```powershell
$DATA = New-Item -ItemType Directory -Path "$env:TEMP\raven-ash-$([guid]::NewGuid())"
.\target\release\ash.exe --data-dir $DATA.FullName init
.\target\release\ash.exe --data-dir $DATA.FullName banner
.\target\release\ash.exe --data-dir $DATA.FullName   # interactive welcome
```

Start the complete per-profile daemon and check the authenticated local pipe:

```powershell
$DATA = Join-Path $env:LOCALAPPDATA "RavenNode"
.\target\release\raven-node.exe service --data-dir $DATA `
  --lan-listen 0.0.0.0:7420 --ble-listen 127.0.0.1:0
# In another terminal:
.\target\release\ash.exe --data-dir $DATA ipc-ping
```

The pipe name is a deterministic hash of the canonical profile path. Its
protected DACL grants access only to the current user; remote clients are
rejected, and both endpoints additionally verify the peer process user SID and
Windows session. Any lookup or authorization failure closes the connection.

Tests:

```powershell
cargo test -p raven-core -p ash
cargo test -p raven-core --test reliability
```

Windows-native tests in `raven-node` exercise pipe creation, mutual peer
authorization, framing, and first-instance squatting protection:

```powershell
cargo test -p raven-node
```

## Cross-compile from macOS / Linux → Windows

Prefer native Windows CI if you need a signed release. Cross-compile is for developer convenience.

### Option A — `cargo` + `x86_64-pc-windows-gnu` (mingw)

```bash
# macOS example (Homebrew)
brew install mingw-w64
rustup target add x86_64-pc-windows-gnu

cd /path/to/hybrid_messenger/node
cargo build -p raven-core -p raven-node -p ash \
  --release --target x86_64-pc-windows-gnu
```

Outputs:

```
target/x86_64-pc-windows-gnu/release/ash.exe
target/x86_64-pc-windows-gnu/release/raven-node.exe
```

### Option B — `x86_64-pc-windows-msvc` via `cargo-xwin` / `cross`

```bash
cargo install cargo-xwin
rustup target add x86_64-pc-windows-msvc
cd /path/to/hybrid_messenger/node
cargo xwin build -p raven-node -p ash --release --target x86_64-pc-windows-msvc
```

Or with [cross](https://github.com/cross-rs/cross):

```bash
cargo install cross --git https://github.com/cross-rs/cross
cross build -p ash -p raven-node --release --target x86_64-pc-windows-msvc
```

**Honest blockers:** MSVC cross from non-Windows may need Windows SDK / linker setup; GNU targets can differ in panic/unwind behavior. Validate the `.exe` on a real Windows host before demos.

## Shim name `ash`

Cargo `[[bin]] name = "ash"` already produces the correct product name on every OS:

| OS | Binary |
|---|---|
| Windows | `ash.exe` |
| macOS / Linux | `ash` |

Do not rename to `raven-ash` for demos — docs and welcome banner assume `ash`.

## What Windows packaging is *not* yet

| Item | Status |
|---|---|
| MSI / MSIX installer | **Not ready** |
| Code signing | **Not ready** |
| Windows LAN settings UI in WinUI app | **Not ready** (iOS Account → Serverless LAN only) |
| BLE raw `RavenEnvelopeV1` on Windows GATT | **Not ready** |

Do not use the legacy raw/`unsafe-interim` demo as a substitute. The Windows
release gate is a real PairInit/indexed-session message plus authenticated ACK
through native named-pipe IPC on two Windows profiles.
