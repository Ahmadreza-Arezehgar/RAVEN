# Windows terminal-path smoke: ash init → doctor → send teach / fail-closed.
# Sibling of ash_menu_smoke.sh. Not an install helper (do not put under scripts/install/).
#
# Evidence rules (SRE Perf):
#   - doctor IPC-up alone is NOT enough (identity + messaging_path required)
#   - never silent skip / never green on missing ash.exe
#   - do NOT call node/scripts/install.sh
#
# Usage (from node/):
#   pwsh -File scripts/ash_doctor_send_smoke.ps1
#
# Exit 0 only when every required string is present.
# If ash.exe is missing after cargo build -p ash: exit 1 with
#   "MSVC ash binary missing — blocked on Windows Platform PR1"

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Fail([string]$Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}

function Require-Match([string]$Haystack, [string]$Pattern, [string]$What) {
    if ($Haystack -notmatch $Pattern) {
        Write-Host "----- captured output -----" -ForegroundColor Yellow
        Write-Host $Haystack
        Write-Host "----- end output -----" -ForegroundColor Yellow
        Fail "$What (pattern: $Pattern)"
    }
}

$NodeRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $NodeRoot

$Ash = Join-Path $NodeRoot "target\debug\ash.exe"
$Node = Join-Path $NodeRoot "target\debug\raven-node.exe"

if (-not (Test-Path -LiteralPath $Ash)) {
    Write-Host "ash.exe missing — cargo build -p ash -p raven-node (debug)"
    & cargo build -p ash -p raven-node
    if ($LASTEXITCODE -ne 0) {
        Fail "cargo build -p ash -p raven-node failed (exit $LASTEXITCODE)"
    }
}

if (-not (Test-Path -LiteralPath $Ash)) {
    Fail "MSVC ash binary missing — blocked on Windows Platform PR1"
}
if (-not (Test-Path -LiteralPath $Node)) {
    Write-Host "raven-node.exe missing — cargo build -p raven-node (debug)"
    & cargo build -p raven-node
    if ($LASTEXITCODE -ne 0) {
        Fail "cargo build -p raven-node failed (exit $LASTEXITCODE)"
    }
}
if (-not (Test-Path -LiteralPath $Node)) {
    Fail "MSVC raven-node.exe missing after cargo build — blocked on Windows Platform PR1"
}

$env:RAVEN_IDENTITY_BACKEND = "locked-file"
$env:NO_COLOR = "1"
$env:TERM = "dumb"

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("raven-ash-win-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Data = Join-Path $Work "data"
New-Item -ItemType Directory -Force -Path $Data | Out-Null

function Invoke-AshCapture {
    param(
        [string[]]$AshArgs,
        [string]$StdinText = $null,
        [int]$TimeoutSec = 90
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ash
    $psi.Arguments = ($AshArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "
    $psi.WorkingDirectory = $NodeRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    # Inherit $env:RAVEN_IDENTITY_BACKEND / NO_COLOR from this process.
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if ($null -ne $StdinText) {
        $p.StandardInput.Write($StdinText)
        $p.StandardInput.Close()
    } else {
        $p.StandardInput.Close()
    }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Fail "ash $($AshArgs -join ' ') exceeded ${TimeoutSec}s — refusing hang-as-pass"
    }
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    return @{ ExitCode = $p.ExitCode; Text = ($stdout + "`n" + $stderr) }
}

try {
    Write-Host "=== ash doctor→send smoke workdir=$Work ==="
    Write-Host "ash=$Ash"

    $init = Invoke-AshCapture -AshArgs @("--data-dir", $Data, "init")
    if ($init.ExitCode -ne 0) {
        Fail "ash init exited $($init.ExitCode)"
    }
    Require-Match $init.Text "address=" "ash init must print address="
    Require-Match $init.Text "pub_hex=" "ash init must print pub_hex="
    Require-Match $init.Text "fingerprint=" "ash init must print fingerprint="

    $who = Invoke-AshCapture -AshArgs @("--data-dir", $Data, "whoami")
    if ($who.ExitCode -ne 0) {
        Fail "ash whoami exited $($who.ExitCode)"
    }
    Require-Match $who.Text "address" "ash whoami must show address"
    Require-Match $who.Text "pub_hex" "ash whoami must show pub_hex"

    $doc = Invoke-AshCapture -AshArgs @("--data-dir", $Data, "doctor")
    # doctor is diagnostic; require identity + messaging_path even if exit != 0
    if ($doc.Text -notmatch "serverless_rvn1") {
        Write-Host $doc.Text
        Fail "ash doctor must show messaging path serverless_rvn1 (IPC-up alone is not Proven)"
    }
    if ($doc.Text -notmatch "identity:\s*present" -and $doc.Text -notmatch "identity present") {
        Write-Host $doc.Text
        Fail "ash doctor must show identity present (IPC-up / daemon_state alone is not Proven)"
    }
    Write-Host "doctor: identity + serverless_rvn1 OK (IPC-up not used as pass)"

    # Interactive line-menu send teach path (Windows uses line_menu_loop).
    # clap `ash send` / `ash contact add` are not dispatched in ash run() today;
    # the wired path is the numbered menu. Empty book → fail-closed teach.
    # 1 = Send; n = do not add a contact now; q = quit.
    $menu = Invoke-AshCapture -AshArgs @("--data-dir", $Data) -StdinText "1`nn`nq`n" -TimeoutSec 90
    $teach = ($menu.Text -match "no pinned contacts") -or
             ($menu.Text -match "Add a contact first") -or
             ($menu.Text -match "empty message")
    if (-not $teach) {
        Write-Host $menu.Text
        Fail "send teach / fail-closed path missing (need no-contact or empty-message evidence)"
    }
    if ($menu.Text -notmatch "fly safe") {
        Write-Host $menu.Text
        Fail "interactive ash did not reach quit (fly safe) — refusing partial menu"
    }
    Write-Host "send teach / fail-closed OK"

    Write-Host "=== ASH DOCTOR SEND SMOKE PASSED ==="
    exit 0
}
finally {
    if (Test-Path -LiteralPath $Work) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
