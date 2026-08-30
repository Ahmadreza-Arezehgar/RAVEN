# Windows — combined development service (product release still held)

**Do not** replace system shells. Prefer `raven.exe` as the unambiguous CLI; `ash.exe` is an alternate name for the same binary.

## Install script

```powershell
# Explicit development-only combined service:
powershell -ExecutionPolicy Bypass -File node/scripts/install/windows_service.ps1 `
  -AllowExperimentalBridgeHarness
```

The script refuses to register anything without that explicit switch. It is not
a product installer: it launches secure LAN-direct, the authenticated bridge
listener, and same-user named-pipe IPC together, but the required native
two-profile Windows message/ACK validation is still outstanding.

Before task registration or start, the helper runs `raven init` explicitly.
Installer locks and rollback backups live under the separate per-user
`RavenNode\installer-state` directory, never under `RavenNode\data`; this keeps
the protected identity profile clean for strict first initialization. Supplying
custom `-DataDir`, `-BinDir`, or `-InstallStateDir` values is allowed only when
all three directories are distinct and none contains another.

The scheduled task is registered with `ExecutionTimeLimit=PT0S`, so Windows
does not apply its usual 72-hour task limit to the always-on node. The installer
does **not** request elevation or silently change Windows Firewall.

## Per-user background process (V1)

```powershell
$Data = Join-Path $env:LOCALAPPDATA "RavenNode\data"
$Node = Join-Path $env:LOCALAPPDATA "RavenNode\bin\raven-node.exe"
Start-Process -FilePath $Node `
  -ArgumentList @("service","--data-dir",$Data,"--lan-listen","0.0.0.0:7420","--bridge-listen","0.0.0.0:7422","--ble-listen","127.0.0.1:7421","--timeout-secs","0") `
  -WindowStyle Hidden
```

## Named pipe IPC

- Implemented pipe name: `\\.\pipe\raven-node-<profile-hash>`; the hash is derived from the canonical profile path and contains no identity secret.
- The server uses a protected current-user-only DACL, rejects remote clients, and verifies client user SID + Windows session. The client performs the reciprocal server SID + session check.
- Framing limits, 10s request/write deadlines, the 45s server `LanDial` budget, and a 50s client response deadline are enforced; authorization errors fail closed.
- There is no plaintext/demo fallback; secure sends fail closed on Windows.
- Run `raven-node service ...` in the foreground and `ash ipc-ping` from a second terminal for local validation. Do not call it release-ready until the two-profile message/ACK gate passes on Windows.

## Windows Firewall (manual, Private networks only)

LAN peers need inbound TCP `7420`; authenticated bridge/relay peers use inbound
TCP `7422`. First confirm Windows classifies the active LAN as `Private`:

```powershell
Get-NetConnectionProfile | Format-Table Name, InterfaceAlias, NetworkCategory
```

If the trusted local network is `Private`, an administrator may add one
program-scoped, local-subnet-only rule for the default install path:

```powershell
$Node = Join-Path $env:LOCALAPPDATA "RavenNode\bin\raven-node.exe"
New-NetFirewallRule `
  -Name "RavenNode-Terminal-Private-LAN" `
  -DisplayName "Raven terminal LAN (Private subnet only)" `
  -Direction Inbound -Action Allow -Enabled True `
  -Profile Private -RemoteAddress LocalSubnet `
  -Program $Node -Protocol TCP -LocalPort 7420,7422
```

Do not create an `Any`/`Public` rule and do not expose the named-pipe IPC (it is
local-only). On both devices, validate the peer's actual LAN address before
testing messages:

```powershell
Test-NetConnection -ComputerName <PEER_LAN_IP> -Port 7420
```

Remove only this documented rule when it is no longer needed:

```powershell
Remove-NetFirewallRule -Name "RavenNode-Terminal-Private-LAN"
```

## Uninstall

Stop and unregister only the exact scheduled-task name printed by the installer,
then remove its separate `RavenNode\bin` directory if desired. Preserve and
back up `RavenNode\data`: it contains identity and history. Never delete an
unrelated `ash.exe` on `PATH` that is not Raven's. `RavenNode\installer-state`
contains only installer coordination/rollback material and is not an identity
backup.
