$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendRoot = Join-Path $Root "backend"
$RuntimeRoot = Join-Path $Root "runtime"
$LogDir = Join-Path $RuntimeRoot "logs"
$PidDir = Join-Path $RuntimeRoot "pids"
$Python = Join-Path $RuntimeRoot ".venv\Scripts\python.exe"
$SolverRoot = Join-Path $Root "vendor\turnstile-solver"
$SolverPython = Join-Path $SolverRoot ".venv\Scripts\python.exe"
$HelperScript = Join-Path $Root "tools\hotmail_helper.py"
$PlaywrightNode = Join-Path $RuntimeRoot ".venv\Lib\site-packages\playwright\driver\node.exe"

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

# Some Windows Python environments contain Playwright but not its bundled
# Node launcher. Reuse the installed Node runtime when that file is missing.
$SystemNode = "C:\Program Files\nodejs\node.exe"
if (-not (Test-Path -LiteralPath $PlaywrightNode) -and (Test-Path -LiteralPath $SystemNode)) {
    Copy-Item -LiteralPath $SystemNode -Destination $PlaywrightNode -Force
}

$webUp = $false
try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:3080/api/health" -TimeoutSec 2
    if ($health.service -eq "progrok-registration") {
        $webUp = $true
    }
} catch {}

if (-not (Test-Path -LiteralPath $Python)) {
    throw "ProGrok Python runtime was not found: $Python"
}

New-Item -ItemType Directory -Force -Path $LogDir, $PidDir | Out-Null
if (-not $webUp) {
    $app = Start-Process -FilePath $Python -ArgumentList @(
        "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "3080", "--workers", "1"
    ) -WorkingDirectory $BackendRoot -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $LogDir "app.out.log") `
        -RedirectStandardError (Join-Path $LogDir "app.err.log") -PassThru

    $app.Id | Set-Content -LiteralPath (Join-Path $PidDir "app.pid") -Encoding ascii
}

# Start the optional solver separately so a slow Camoufox initialization never
# delays the Web UI after Windows logon.
try {
    # Camoufox can take several seconds to answer while it is warming up. A
    # short probe here used to start another solver on the same port.
    $solverHealth = Invoke-RestMethod -Uri "http://127.0.0.1:5072/health" -TimeoutSec 15
} catch {
    $solverHealth = $null
}

if ($null -eq $solverHealth -and (Test-Path -LiteralPath $SolverPython)) {
    $env:TURNSTILE_LAZY = "1"
    $env:TURNSTILE_REUSE_PAGE = "1"
    $env:TURNSTILE_IDLE_SEC = "600"
    $solver = Start-Process -FilePath $SolverPython -ArgumentList @(
        "api_solver.py", "--browser_type", "camoufox", "--thread", "1",
        "--proxy", "--host", "127.0.0.1", "--port", "5072"
    ) -WorkingDirectory $SolverRoot -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $LogDir "solver.out.log") `
        -RedirectStandardError (Join-Path $LogDir "solver.err.log") -PassThru
    $solver.Id | Set-Content -LiteralPath (Join-Path $PidDir "solver.pid") -Encoding ascii
}

try {
    $helperHealth = Invoke-RestMethod -Uri "http://127.0.0.1:17373/health" -TimeoutSec 2
} catch {
    $helperHealth = $null
}

if ($null -eq $helperHealth -and (Test-Path -LiteralPath $HelperScript)) {
    $helper = Start-Process -FilePath $Python -ArgumentList @(
        $HelperScript, "--host", "127.0.0.1", "--port", "17373"
    ) -WorkingDirectory $Root -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $LogDir "hotmail-helper.out.log") `
        -RedirectStandardError (Join-Path $LogDir "hotmail-helper.err.log") -PassThru
    $helper.Id | Set-Content -LiteralPath (Join-Path $PidDir "hotmail-helper.pid") -Encoding ascii
}
