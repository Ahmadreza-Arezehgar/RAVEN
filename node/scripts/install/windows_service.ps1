# Install always-on raven-node for the current Windows user (no MSI / no system ash overwrite).
param(
    [string]$DataDir = $(Join-Path $env:LOCALAPPDATA "RavenNode"),
    [string]$BinDir = $(Join-Path $env:LOCALAPPDATA "RavenNode"),
    [switch]$AllowExperimentalBridgeHarness
)

$ErrorActionPreference = "Stop"

if (-not $AllowExperimentalBridgeHarness) {
    throw @"
Windows product installation is held pending a native two-profile
PairInit/indexed-message/authenticated-ACK validation. The same-user named-pipe
transport is implemented, but this script still installs only the raw bridge
development harness. Nothing was installed. To opt into that harness, rerun
with -AllowExperimentalBridgeHarness.
"@
}

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

Push-Location $Root
cargo build -p raven-node -p ash --release
Pop-Location

Copy-Item "$Root\target\release\raven-node.exe" (Join-Path $BinDir "raven-node.exe") -Force
Copy-Item "$Root\target\release\ash.exe" (Join-Path $BinDir "raven.exe") -Force
# Optional product alias — never touches system ash
Copy-Item "$Root\target\release\ash.exe" (Join-Path $BinDir "ash.exe") -Force

$exe = Join-Path $BinDir "raven-node.exe"
$args = "bridge --data-dir `"$DataDir`" --lan-listen 127.0.0.1:7420 --ble-listen 127.0.0.1:7421 --timeout-secs 0"

# Register a per-user logon task (survives reboot; no admin service required for V1 software path).
$taskName = "RavenNodeBridge"
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute $exe -Argument $args
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "RAVEN raven-node bridge (serverless)" | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Warning "EXPERIMENTAL BRIDGE HARNESS ONLY: native Windows secure-send E2E is not release-validated"
Write-Host "installed development task $taskName"
Write-Host "data-dir=$DataDir"
Write-Host "bin-dir=$BinDir (raven.exe / ash.exe)"
Write-Host "Named-pipe IPC is implemented; this task does not launch it. See WINDOWS_SERVICE.md"
