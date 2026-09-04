# Windows — always-on raven-node + named-pipe IPC notes

**Do not** replace system shells. Prefer `raven.exe` as the unambiguous CLI; `ash.exe` is an alternate name for the same binary.

## Install script

```powershell
# From repo:
#   powershell -ExecutionPolicy Bypass -File node/scripts/install/windows_service.ps1
```

See `windows_service.ps1` for build + Task Scheduler registration. This is a **per-user Task Scheduler** task (not an SCM service flip).

## Per-user background process (V1)

`raven-node service` is the always-on command: named-pipe IPC + LAN + bridge (parity with Unix `service`).

```powershell
$Data = Join-Path $env:LOCALAPPDATA "RavenNode"
Start-Process -FilePath "$env:LOCALAPPDATA\RavenNode\raven-node.exe" `
  -ArgumentList @("service","--data-dir",$Data,"--lan-listen","127.0.0.1:7420","--ble-listen","127.0.0.1:7421","--timeout-secs","0") `
  -WindowStyle Hidden
```

Dedicated IPC only: `raven-node ipc --data-dir $Data`.

## Named pipe IPC

- Server binds `WINDOWS_NAMED_PIPE` (`\\.\pipe\raven-node`) with a **current-user DACL** (no World/Everyone ACE). DACL setup is **fail-closed**: if the descriptor cannot be built, the process does not bind.
- Framing is the same length-prefixed JSON as Unix UDS (`raven-core::ipc`, IPC_VERSION=1): Ping, Status, SetPolicy, EnqueueSealed, LanDial. Secrets (`seed` / `private_key` / `plaintext` / `recovery`) are refused; EnqueueSealed is already-sealed only.
- Unix ash uses UDS; Windows ash client / `ash doctor` named-pipe connect is a CLI DX follow-up (`ipc_transport_missing` until then). Do not treat a missing ash client as a server gap.
- Software path: framing + refuse-secret-fields are shared; OS bind is platform-specific.

## Try / Proven

`rust-windows` (MSVC) must compile `raven-node` including this server. Unit tests cover the exact pipe name and current-user DACL construction.

**Proven** for named-pipe bind/DACL requires a Windows CI cite after merge (`rust-windows` job: `cargo test -p raven-node` / `cargo build -p raven-node`). Do not claim Proven from Linux/macOS CI alone.

## Uninstall

Stop the scheduled task / process; delete `$env:LOCALAPPDATA\RavenNode`. Never delete unrelated `ash.exe` on PATH that is not Raven's.
