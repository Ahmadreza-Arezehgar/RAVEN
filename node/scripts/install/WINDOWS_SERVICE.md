# Windows — always-on raven-node (notes)

**Do not** replace system shells. Prefer `raven.exe` as the unambiguous CLI; `ash.exe` is an alternate name for the same binary.

## Per-user background process (V1)

```powershell
# Build
cd path\to\hybrid_messenger\node
cargo build -p raven-node -p ash --release

# Data dir (no secrets in docs)
$Data = Join-Path $env:LOCALAPPDATA "RavenNode"
New-Item -ItemType Directory -Force -Path $Data | Out-Null
Copy-Item .\target\release\raven-node.exe $env:LOCALAPPDATA\RavenNode\
Copy-Item .\target\release\ash.exe $env:LOCALAPPDATA\RavenNode\raven.exe

# Start detached (survives closing the terminal that launched ash/raven)
Start-Process -FilePath "$env:LOCALAPPDATA\RavenNode\raven-node.exe" `
  -ArgumentList @("bridge","--data-dir",$Data,"--lan-listen","127.0.0.1:7420","--ble-listen","127.0.0.1:7421","--timeout-secs","0") `
  -WindowStyle Hidden
```

## Named pipe IPC (design)

- Pipe: `\\.\pipe\raven-node-<sid>` with user DACL only
- Payload: same `raven-core::ipc` frames as UDS on Unix
- Full Windows Service + ACLs: package later; MSI not required for local DoD software path

## Uninstall

Stop the process; delete `$env:LOCALAPPDATA\RavenNode` and any Start Menu shortcuts Raven created. Never delete unrelated `ash.exe` on PATH that is not Raven's.
