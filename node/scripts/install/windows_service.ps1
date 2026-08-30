# Install always-on raven-node for the current Windows user (no MSI / no system ash overwrite).
param(
    [string]$DataDir = $(Join-Path $env:LOCALAPPDATA "RavenNode\data"),
    [string]$BinDir = $(Join-Path $env:LOCALAPPDATA "RavenNode\bin"),
    [string]$InstallStateDir = $(Join-Path $env:LOCALAPPDATA "RavenNode\installer-state"),
    [switch]$AllowExperimentalBridgeHarness
)

$ErrorActionPreference = "Stop"

if (-not $AllowExperimentalBridgeHarness) {
    throw @"
Windows product installation is held pending a native two-profile
PairInit/indexed-message/authenticated-ACK validation. The same-user named-pipe
transport and combined secure service are implemented, but they have not passed
that physical Windows gate. Nothing was installed. To opt into the unvalidated
development service, rerun
with -AllowExperimentalBridgeHarness.
"@
}

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$DataDir = [IO.Path]::GetFullPath($DataDir)
$BinDir = [IO.Path]::GetFullPath($BinDir)
$InstallStateDir = [IO.Path]::GetFullPath($InstallStateDir)
foreach ($path in @($DataDir, $BinDir, $InstallStateDir)) {
    if ([StringComparer]::OrdinalIgnoreCase.Equals($path.TrimEnd([IO.Path]::DirectorySeparatorChar), [IO.Path]::GetPathRoot($path).TrimEnd([IO.Path]::DirectorySeparatorChar))) {
        throw "Refusing to use a drive root as an install directory: $path"
    }
}
$separator = [IO.Path]::DirectorySeparatorChar
function Assert-DisjointDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ([StringComparer]::OrdinalIgnoreCase.Equals($First, $Second) -or
        $First.StartsWith($Second.TrimEnd($separator) + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith($First.TrimEnd($separator) + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be separate and must not contain one another"
    }
}
Assert-DisjointDirectories $DataDir $BinDir "DataDir and BinDir"
Assert-DisjointDirectories $DataDir $InstallStateDir "DataDir and InstallStateDir"
Assert-DisjointDirectories $BinDir $InstallStateDir "BinDir and InstallStateDir"
function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a reparse-point install path component: $cursor"
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}
Assert-NoReparsePoint $DataDir
Assert-NoReparsePoint $BinDir
Assert-NoReparsePoint $InstallStateDir

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstallStateDir | Out-Null
$dataDirWasEmpty = $null -eq (Get-ChildItem -LiteralPath $DataDir -Force | Select-Object -First 1)

$installLockPath = Join-Path $InstallStateDir ".service-install.lock"
try {
    $installLock = [IO.File]::Open(
        $installLockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
} catch {
    throw "Another Raven service install appears to be running for this profile: $installLockPath"
}

try {

    Push-Location $Root
    try {
        cargo build --locked -p raven-node -p ash --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmss.fffZ")
    $backupDir = Join-Path $InstallStateDir "install-backups\$stamp-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $backupDir | Out-Null

    $destinations = @(
        (Join-Path $BinDir "raven-node.exe"),
        (Join-Path $BinDir "raven.exe"),
        (Join-Path $BinDir "ash.exe")
    )
    $destinationExisted = @{}
    foreach ($destination in $destinations) {
        Assert-NoReparsePoint $destination
        $destinationExisted[$destination] = Test-Path -LiteralPath $destination
        if ($destinationExisted[$destination]) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($destination)))
        }
    }

    function Restore-Binaries {
        foreach ($destination in $destinations) {
            $backup = Join-Path $backupDir ([IO.Path]::GetFileName($destination))
            $restored = $false
            for ($restoreAttempt = 0; $restoreAttempt -lt 50; $restoreAttempt++) {
                try {
                    if ($destinationExisted[$destination] -and (Test-Path -LiteralPath $backup)) {
                        Copy-Item -LiteralPath $backup -Destination $destination -Force
                    } elseif (-not $destinationExisted[$destination] -and (Test-Path -LiteralPath $destination)) {
                        Remove-Item -LiteralPath $destination -Force
                    }
                    $restored = $true
                    break
                } catch {
                    if ($restoreAttempt -eq 49) { throw }
                    Start-Sleep -Milliseconds 100
                }
            }
            if (-not $restored) {
                throw "Could not restore $destination during rollback"
            }
        }
    }

    $exe = Join-Path $BinDir "raven-node.exe"
    $args = "service --data-dir `"$DataDir`" --lan-listen 0.0.0.0:7420 --bridge-listen 0.0.0.0:7422 --ble-listen 127.0.0.1:7421 --timeout-secs 0"

    # Register one task per data profile. This avoids replacing another Raven
    # profile's scheduled task when multiple test identities share the same
    # user. Windows paths are case-insensitive, and a trailing separator does
    # not identify a different directory, so canonicalize both properties
    # before deriving the stable task key.
    $profileKeySeparators = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $profileKey = $DataDir.TrimEnd($profileKeySeparators).ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $profileHash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($profileKey))[0..5] | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }
    $taskName = "RavenNodeBridge-$profileHash"
    $oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $oldTaskXml = $null
    $oldTaskWasRunning = $false
    if ($oldTask) {
        $oldTaskXml = Export-ScheduledTask -TaskName $taskName
        # Comparing the enum through its stable string works across Windows
        # PowerShell and PowerShell 7 CIM projections.
        $oldTaskWasRunning = $oldTask.State.ToString() -eq "Running"
    }

    try {
        if ($oldTask) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            for ($stopAttempt = 0; $stopAttempt -lt 50; $stopAttempt++) {
                $stoppingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if (-not $stoppingTask -or $stoppingTask.State.ToString() -ne "Running") { break }
                Start-Sleep -Milliseconds 100
            }
            if ($stoppingTask -and $stoppingTask.State.ToString() -eq "Running") {
                throw "Existing Raven scheduled task did not stop; binaries were left unchanged"
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        Copy-Item "$Root\target\release\raven-node.exe" $destinations[0] -Force
        Copy-Item "$Root\target\release\raven.exe" $destinations[1] -Force
        # Optional product alias — never touches system ash.
        Copy-Item "$Root\target\release\ash.exe" $destinations[2] -Force

        if ($dataDirWasEmpty -and $null -ne (Get-ChildItem -LiteralPath $DataDir -Force | Select-Object -First 1)) {
            throw "Installer metadata polluted a fresh identity profile before raven init"
        }
        & $destinations[1] --data-dir $DataDir init
        if ($LASTEXITCODE -ne 0) {
            throw "raven init failed with exit code $LASTEXITCODE"
        }

        $action = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        # Scheduled Tasks otherwise defaults to a 72-hour execution limit,
        # which silently kills an intended always-on per-user node. PT0S is
        # represented by TimeSpan.Zero and means no execution time limit.
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "RAVEN secure LAN + authenticated bridge + same-user IPC service" | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $ready = $false
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            $runningTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            & $destinations[1] --data-dir $DataDir ipc-ping *> $null
            $ipcReady = $LASTEXITCODE -eq 0
            $bridgePublished = $false
            $bridgeFile = Join-Path $DataDir "service-bridge.addr"
            if (Test-Path -LiteralPath $bridgeFile) {
                $publishedAddress = (Get-Content -LiteralPath $bridgeFile -Raw).Trim()
                $bridgePublished = $publishedAddress -match ':7422$'
            }
            $bridgeClient = [Net.Sockets.TcpClient]::new()
            try {
                $bridgeConnect = $bridgeClient.ConnectAsync("127.0.0.1", 7422)
                $bridgeLive = $bridgeConnect.Wait(200) -and $bridgeClient.Connected
            } catch {
                $bridgeLive = $false
            } finally {
                $bridgeClient.Dispose()
            }
            if ($runningTask -and $runningTask.State.ToString() -eq "Running" -and $ipcReady -and $bridgePublished -and $bridgeLive) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ready) {
            throw "Scheduled task started, but Raven's same-user IPC + authenticated bridge did not become ready"
        }
    } catch {
        $installError = $_
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        for ($stopAttempt = 0; $stopAttempt -lt 50; $stopAttempt++) {
            $stoppingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $stoppingTask -or $stoppingTask.State.ToString() -ne "Running") { break }
            Start-Sleep -Milliseconds 100
        }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Restore-Binaries
        if ($oldTaskXml) {
            Register-ScheduledTask -TaskName $taskName -Xml $oldTaskXml | Out-Null
            if ($oldTaskWasRunning) {
                Start-ScheduledTask -TaskName $taskName
            }
        }
        throw $installError
    }

    Write-Warning "UNVALIDATED WINDOWS SERVICE: native two-profile secure-send E2E still requires a physical Windows gate"
    Write-Host "installed development service task $taskName"
    Write-Host "data-dir=$DataDir"
    Write-Host "bin-dir=$BinDir (raven.exe / ash.exe)"
    Write-Host "installer-state=$InstallStateDir"
    Write-Host "rollback backup=$backupDir"
    Write-Host "Named-pipe IPC + secure LAN :7420 + authenticated bridge :7422 are enabled. See WINDOWS_SERVICE.md"
} finally {
    if ($installLock) { $installLock.Dispose() }
}
