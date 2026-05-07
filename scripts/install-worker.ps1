#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs exo worker node on a second Windows host.

.DESCRIPTION
    - Clones the ubisoft/exo repo (peter/wip branch)
    - Installs Python dependencies via uv
    - Builds the dashboard
    - Downloads llama.cpp b7836 CUDA binaries
    - Opens firewall ports 52415 (API) and 4001 (libp2p)
    - Creates a startup script

.PARAMETER InstallDir
    Directory to install exo into. Default: C:\exo

.PARAMETER NoApi
    Start as worker-only node (no dashboard/API).

.PARAMETER SkipDashboard
    Skip the npm dashboard build step.

.PARAMETER CudaVersion
    CUDA version suffix for llama.cpp download (e.g. cu12.4, cu12.2, cu11.7).
    Default: cu12.4

.EXAMPLE
    .\install-worker.ps1
    .\install-worker.ps1 -InstallDir D:\exo -NoApi -CudaVersion cu12.2
#>
param(
    [string]$InstallDir   = "C:\exo",
    [switch]$NoApi,
    [switch]$SkipDashboard,
    [string]$CudaVersion  = "cu12.4"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LlamaBuild   = "b7836"
$LlamaZip     = "llama-$LlamaBuild-bin-win-cuda-$CudaVersion-x64.zip"
$LlamaUrl     = "https://github.com/ggerganov/llama.cpp/releases/download/$LlamaBuild/$LlamaZip"
$RepoUrl      = "git@github.com:ubisoft/exo.git"
$Branch       = "supportWindows"
$LibP2PPort   = 4001
$ApiPort      = 52415

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Assert-Command([string]$cmd, [string]$install) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] '$cmd' not found. $install" -ForegroundColor Red
        exit 1
    }
}

# ── prerequisite checks ───────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

Assert-Command "git"    "Install Git from https://git-scm.com"
Assert-Command "uv"     "Install uv: irm https://astral.sh/uv/install.ps1 | iex"
Assert-Command "python" "Install Python 3.10 from https://python.org"

$pyVer = python --version 2>&1
Write-Host "  Python : $pyVer"
Write-Host "  uv     : $(uv --version)"
Write-Host "  git    : $(git --version)"

if (-not (Get-Command "npm" -ErrorAction SilentlyContinue) -and -not $SkipDashboard) {
    Write-Host "[WARN] npm not found — dashboard build will be skipped." -ForegroundColor Yellow
    $SkipDashboard = $true
}

# ── clone ─────────────────────────────────────────────────────────────────────

Write-Step "Cloning repository into $InstallDir"

if (Test-Path $InstallDir) {
    Write-Host "  Directory exists — pulling latest changes"
    git -C $InstallDir fetch ubisoft
    git -C $InstallDir checkout $Branch
    git -C $InstallDir pull ubisoft $Branch
} else {
    git clone $RepoUrl $InstallDir
    git -C $InstallDir checkout $Branch
}

Set-Location $InstallDir

# ── python deps ───────────────────────────────────────────────────────────────

Write-Step "Installing Python dependencies"
$env:UV_SKIP_WHEEL_FILENAME_CHECK = "1"
uv sync

# ── dashboard ─────────────────────────────────────────────────────────────────

if (-not $SkipDashboard) {
    Write-Step "Building dashboard"
    Push-Location "$InstallDir\dashboard"
    npm install
    npm run build
    Pop-Location
}

# ── llama.cpp binaries ────────────────────────────────────────────────────────

Write-Step "Downloading llama.cpp $LlamaBuild ($CudaVersion)"

$tmpZip = "$env:TEMP\$LlamaZip"
$tmpDir = "$env:TEMP\llama-extract"

if (-not (Test-Path $tmpZip)) {
    Write-Host "  Downloading $LlamaUrl"
    Invoke-WebRequest -Uri $LlamaUrl -OutFile $tmpZip -UseBasicParsing
} else {
    Write-Host "  Archive already cached at $tmpZip"
}

Write-Host "  Extracting..."
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir

# Copy only the needed files
$needed = @(
    "llama-server.exe",
    "ggml.dll", "ggml-base.dll", "ggml-cuda.dll", "ggml-rpc.dll",
    "llama.dll", "mtmd.dll", "libomp140.x86_64.dll"
)
$cpuDlls = Get-ChildItem $tmpDir -Filter "ggml-cpu-*.dll" -Recurse

foreach ($f in $needed) {
    $src = Get-ChildItem $tmpDir -Filter $f -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($src) {
        Copy-Item $src.FullName "$InstallDir\" -Force
        Write-Host "  Copied $f"
    } else {
        Write-Host "  [WARN] $f not found in archive" -ForegroundColor Yellow
    }
}
foreach ($dll in $cpuDlls) {
    Copy-Item $dll.FullName "$InstallDir\" -Force
    Write-Host "  Copied $($dll.Name)"
}

# ── firewall rules ────────────────────────────────────────────────────────────

Write-Step "Configuring firewall"

$rules = @(
    @{ Name = "exo API";     Port = $ApiPort;    Proto = "TCP" },
    @{ Name = "exo libp2p";  Port = $LibP2PPort; Proto = "TCP" }
)
foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Rule '$($r.Name)' already exists — skipping"
    } else {
        New-NetFirewallRule -DisplayName $r.Name `
            -Direction Inbound -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port `
            -Profile Private | Out-Null
        Write-Host "  Created rule: $($r.Name) ($($r.Proto)/$($r.Port))"
    }
}

# ── startup script ────────────────────────────────────────────────────────────

Write-Step "Writing startup script"

$startScript = @"
# exo worker startup script — generated by install-worker.ps1
Set-Location "$InstallDir"

`$env:UV_SKIP_WHEEL_FILENAME_CHECK = "1"
`$env:EXO_LLAMA_SERVER_PATH        = "$InstallDir\llama-server.exe"
`$env:EXO_LIBP2P_LISTEN_PORT       = "$LibP2PPort"
`$env:EXO_LIBP2P_LISTEN_ADDR       = "0.0.0.0"

$(if ($NoApi) { 'uv run exo --no-api' } else { 'uv run exo' })
"@

$startPath = "$InstallDir\start-exo.ps1"
Set-Content -Path $startPath -Value $startScript -Encoding UTF8
Write-Host "  Written to $startPath"

# ── done ─────────────────────────────────────────────────────────────────────

Write-Host @"

==========================================================
  Installation complete!

  Start exo:
    powershell -ExecutionPolicy Bypass -File "$startPath"

  Cluster will form automatically via mDNS once both
  nodes are running on the same LAN.
==========================================================
"@ -ForegroundColor Green
