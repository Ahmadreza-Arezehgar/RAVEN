$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location -LiteralPath $PSScriptRoot

$script:RdapNativeExitCode = 1

function Invoke-RdapNative {
    param(
        [Parameter(Mandatory = $true)]
        [String]$Executable,
        [Parameter(Mandatory = $true)]
        [String[]]$Arguments,
        [Switch]$Quiet
    )

    $previousPreference = $ErrorActionPreference
    $exitCode = 1
    try {
        # Windows PowerShell 5.1 can promote native stderr to a terminating
        # NativeCommandError when the script-wide preference is Stop.  Native
        # success/failure is defined by its process exit code instead.
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = -1
        if ($Quiet) {
            & $Executable @Arguments 2>$null
        }
        else {
            & $Executable @Arguments
        }
        $exitCode = [Int]$LASTEXITCODE
    }
    catch {
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previousPreference
        $script:RdapNativeExitCode = $exitCode
    }
}

$versionProbe = @(
    '-c',
    'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
)
$pythonCommand = $null
$pythonPrefixArguments = @()
$pythonCandidates = @(
    Get-Command python.exe -CommandType Application -All -ErrorAction SilentlyContinue
)
foreach ($candidate in $pythonCandidates) {
    $candidatePath = $candidate.Path
    if ([String]::IsNullOrWhiteSpace($candidatePath)) {
        continue
    }
    Invoke-RdapNative -Executable $candidatePath -Arguments $versionProbe -Quiet
    if ($script:RdapNativeExitCode -eq 0) {
        # Get-Command can return every python.exe on PATH.  Keep one verified
        # executable path; invoking the array's .Source property joins all
        # candidates into one invalid command string on Windows PowerShell.
        $pythonCommand = $candidatePath
        break
    }
}

if ($null -eq $pythonCommand) {
    $launcherCandidates = @(
        Get-Command py.exe -CommandType Application -All -ErrorAction SilentlyContinue
    )
    foreach ($candidate in $launcherCandidates) {
        $candidatePath = $candidate.Path
        if ([String]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }
        $launcherProbe = @('-3') + $versionProbe
        Invoke-RdapNative -Executable $candidatePath -Arguments $launcherProbe -Quiet
        if ($script:RdapNativeExitCode -eq 0) {
            $pythonCommand = $candidatePath
            $pythonPrefixArguments = @('-3')
            break
        }
    }
}

if ($null -eq $pythonCommand) {
    throw 'Python 3.10 or newer is required via python.exe or py.exe.'
}

$venvPath = Join-Path $PSScriptRoot '.venv'
$venvPython = Join-Path $venvPath 'Scripts\python.exe'
if (Test-Path -LiteralPath $venvPath) {
    $venvItem = Get-Item -LiteralPath $venvPath -Force
    $isReparse = (($venvItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if (-not $venvItem.PSIsContainer -or $isReparse) {
        throw 'Refusing unsafe .venv path; it must be absent or a real directory.'
    }
    $venvUsable = Test-Path -LiteralPath $venvPython -PathType Leaf
    if ($venvUsable) {
        Invoke-RdapNative -Executable $venvPython -Arguments $versionProbe -Quiet
        $venvUsable = ($script:RdapNativeExitCode -eq 0)
    }
    if (-not $venvUsable) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
        $backup = Join-Path $PSScriptRoot ".venv.rdap-backup.$stamp.$PID"
        if (Test-Path -LiteralPath $backup) {
            throw "Refusing to overwrite existing virtualenv backup: $backup"
        }
        Write-Host "* preserving incompatible virtualenv as $backup"
        Move-Item -LiteralPath $venvPath -Destination $backup
    }
}

if (-not (Test-Path -LiteralPath $venvPath)) {
    Write-Host '* creating virtualenv...'
    $venvArguments = @($pythonPrefixArguments) + @('-m', 'venv', $venvPath)
    Invoke-RdapNative -Executable $pythonCommand -Arguments $venvArguments
    if ($script:RdapNativeExitCode -ne 0) {
        throw 'Python failed to create the RDAP virtualenv.'
    }
}

$lockPath = Join-Path $PSScriptRoot 'requirements.lock.txt'
$markerPath = Join-Path $venvPath '.rdap-requirements.sha256'
$lockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
$installedHash = ''
if (Test-Path -LiteralPath $markerPath) {
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    $markerIsReparse = (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($markerItem.PSIsContainer -or $markerIsReparse) {
        throw 'Refusing unsafe dependency-lock marker path.'
    }
    $installedHash = (Get-Content -LiteralPath $markerPath -Raw).Trim()
}

$importsOk = $false
$importProbe = @(
    '-c',
    'import a2a, uvicorn, starlette, cryptography, httpx, zeroconf'
)
Invoke-RdapNative -Executable $venvPython -Arguments $importProbe -Quiet
$importsOk = ($script:RdapNativeExitCode -eq 0)
if ($lockHash -ne $installedHash -or -not $importsOk) {
    Write-Host '* installing verified dependencies...'
    $pipArguments = @('-m', 'pip', 'install', '--require-hashes', '-r', $lockPath)
    Invoke-RdapNative -Executable $venvPython -Arguments $pipArguments
    if ($script:RdapNativeExitCode -ne 0) {
        throw 'Hash-verified RDAP dependency installation failed.'
    }
    [IO.File]::WriteAllText($markerPath, "$lockHash`n")
}

$rdapArguments = @((Join-Path $PSScriptRoot 'rdap.py')) + @($args)
Invoke-RdapNative -Executable $venvPython -Arguments $rdapArguments
exit $script:RdapNativeExitCode
