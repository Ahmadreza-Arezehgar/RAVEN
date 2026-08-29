# Windows — bridge harness (product service still held)

**Do not** replace system shells. Prefer `raven.exe` as the unambiguous CLI; `ash.exe` is an alternate name for the same binary.

## Install script

```powershell
# Explicit development-only bridge harness:
powershell -ExecutionPolicy Bypass -File node/scripts/install/windows_service.ps1 `
  -AllowExperimentalBridgeHarness
```

The script refuses to register anything without that explicit switch. It is not a product installer: the named-pipe `LanDial` transport now exists, but this helper still launches only the bridge harness and the required native two-profile Windows message/ACK validation is outstanding.

## Per-user background process (V1)

```powershell
$Data = Join-Path $env:LOCALAPPDATA "RavenNode"
Start-Process -FilePath "$env:LOCALAPPDATA\RavenNode\raven-node.exe" `
  -ArgumentList @("bridge","--data-dir",$Data,"--lan-listen","127.0.0.1:7420","--ble-listen","127.0.0.1:7421","--timeout-secs","0") `
  -WindowStyle Hidden
```

## Named pipe IPC

- Implemented pipe name: `\\.\pipe\raven-node-<profile-hash>`; the hash is derived from the canonical profile path and contains no identity secret.
- The server uses a protected current-user-only DACL, rejects remote clients, and verifies client user SID + Windows session. The client performs the reciprocal server SID + session check.
- Framing limits, 10s request/write deadlines, the 45s server `LanDial` budget, and a 50s client response deadline are enforced; authorization errors fail closed.
- There is no plaintext/demo fallback; secure sends fail closed on Windows.
- Run `raven-node service ...` in the foreground and `ash ipc-ping` from a second terminal for local validation. Do not call it release-ready until the two-profile message/ACK gate passes on Windows.

## Uninstall

Stop the scheduled task / process; delete `$env:LOCALAPPDATA\RavenNode`. Never delete unrelated `ash.exe` on PATH that is not Raven's.
