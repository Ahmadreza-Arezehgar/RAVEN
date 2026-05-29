# build-windows.ps1
#
# Build a single-file RAVEN.exe for Windows. Run this on a Windows 10/11
# machine (the WinUI 3 toolchain only works on Windows). Output:
#
#   RAVEN-Windows\src\bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\RAVEN.exe
#
# Usage:
#   PS> cd RAVEN-Windows
#   PS> .\build-windows.ps1            # x64 (default)
#   PS> .\build-windows.ps1 -Arch arm64 # ARM64 (Surface Pro X etc.)
#   PS> .\build-windows.ps1 -SkipTests  # don't run unit tests first

[CmdletBinding()]
param(
    [ValidateSet('x64','arm64')]
    [string]$Arch = 'x64',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

# ─── 0. Sanity ──────────────────────────────────────────────────────

Write-Host "→ Checking prerequisites..." -ForegroundColor Cyan

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Error "This script must run on Windows. WinUI 3 toolchain is Windows-only."
    exit 1
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Error "'.NET 8 SDK' not found. Install from https://dotnet.microsoft.com/download/dotnet/8.0 and re-run."
    exit 1
}

$sdks = & dotnet --list-sdks
if (-not ($sdks -match '^8\.')) {
    Write-Error ".NET 8 SDK not found. Installed SDKs:`n$sdks"
    exit 1
}

Write-Host "  .NET SDK : $((& dotnet --version))"
Write-Host "  Arch     : $Arch"
Write-Host ""

# ─── 1. Run unit tests first (cross-platform-safe) ──────────────────

if (-not $SkipTests) {
    Write-Host "→ Running mesh interop tests..." -ForegroundColor Cyan
    & dotnet test "$PSScriptRoot\tests\RAVEN.Windows.Tests.csproj" -c Release --nologo
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Tests failed. Aborting build."
        exit $LASTEXITCODE
    }
    Write-Host ""
}

# ─── 2. Restore + publish self-contained ────────────────────────────

$rid = "win-$Arch"
$projectDir = "$PSScriptRoot\src"

Write-Host "→ Restoring + publishing for $rid..." -ForegroundColor Cyan

& dotnet publish $projectDir\RAVEN.Windows.csproj `
    -c Release `
    -r $rid `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:WindowsAppSDKSelfContained=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=embedded `
    --nologo

if ($LASTEXITCODE -ne 0) {
    Write-Error "Publish failed."
    exit $LASTEXITCODE
}

# ─── 3. Surface the output path ─────────────────────────────────────

$outputDir = "$projectDir\bin\Release\net8.0-windows10.0.19041.0\$rid\publish"
$exe = "$outputDir\RAVEN.exe"

if (-not (Test-Path $exe)) {
    Write-Error "Expected $exe but didn't find it. Inspect $outputDir."
    exit 1
}

$size = (Get-Item $exe).Length / 1MB
Write-Host ""
Write-Host "✓ Build complete." -ForegroundColor Green
Write-Host "  Path : $exe"
Write-Host "  Size : $([math]::Round($size, 1)) MB"
Write-Host ""
Write-Host "Run it directly:"
Write-Host "  PS> & '$exe'"
Write-Host ""
Write-Host "Or copy the entire publish folder if you want every loose dependency"
Write-Host "(not strictly needed because PublishSingleFile=true bundles everything)."
