$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location -LiteralPath $PSScriptRoot

$pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    throw 'Python 3.10 or newer is required and must be available as python.exe.'
}

& $pythonCommand.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
if ($LASTEXITCODE -ne 0) {
    throw 'Python 3.10 or newer is required.'
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
        & $venvPython -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
        $venvUsable = ($LASTEXITCODE -eq 0)
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
    & $pythonCommand.Source -m venv $venvPath
    if ($LASTEXITCODE -ne 0) {
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

& $venvPython -c 'import a2a, uvicorn, starlette, cryptography, httpx, zeroconf' 2>$null
$importsOk = ($LASTEXITCODE -eq 0)
if ($lockHash -ne $installedHash -or -not $importsOk) {
    Write-Host '* installing verified dependencies...'
    & $venvPython -m pip install --require-hashes -r $lockPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Hash-verified RDAP dependency installation failed.'
    }
    [IO.File]::WriteAllText($markerPath, "$lockHash`n")
}

& $venvPython (Join-Path $PSScriptRoot 'rdap.py') @args
exit $LASTEXITCODE
