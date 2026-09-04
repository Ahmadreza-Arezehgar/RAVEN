# Windows — always-on raven-node + named-pipe IPC notes

**Do not** replace system shells. Prefer `raven.exe` as the unambiguous CLI; `ash.exe` is an alternate name for the same binary.

## Install script

```powershell
# From repo:
#   powershell -ExecutionPolicy Bypass -File node/scripts/install/windows_service.ps1
# CI / layout-only (no RavenNodeBridge logon task):
#   powershell -ExecutionPolicy Bypass -File node/scripts/install/windows_service.ps1 -SkipScheduledTask
```

See `windows_service.ps1` for build + Task Scheduler registration.

CI (`rust-windows` in `raven-serverless.yml`) exercises this helper beyond parse-only: it runs the script with `-DataDir` / `-BinDir` under `$env:RUNNER_TEMP` and `-SkipScheduledTask` so release binaries are built and copied (`raven-node.exe`, `raven.exe`, `ash.exe`) without registering a persistent per-user logon task on the runner. Leave `-SkipScheduledTask` off for a real local install. LAN bind stays `127.0.0.1:7420` (B12 hold).

## Per-user background process (V1)

```powershell
$Data = Join-Path $env:LOCALAPPDATA "RavenNode"
Start-Process -FilePath "$env:LOCALAPPDATA\RavenNode\raven-node.exe" `
  -ArgumentList @("bridge","--data-dir",$Data,"--lan-listen","127.0.0.1:7420","--ble-listen","127.0.0.1:7421","--timeout-secs","0") `
  -WindowStyle Hidden
```

## Named pipe IPC

- Pipe name: `\\.\pipe\raven-node` (user DACL only — same framing as Unix UDS via `raven-core::ipc`)
- Unix ash uses UDS; Windows ash falls back to `--send-stdin` spawn until named-pipe client lands in ash
- Software path: framing + refuse-secret-fields are shared; OS bind is platform-specific

## Uninstall

Stop the scheduled task / process; delete `$env:LOCALAPPDATA\RavenNode`. Never delete unrelated `ash.exe` on PATH that is not Raven's.
