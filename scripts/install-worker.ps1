<#
.SYNOPSIS
    Installs exo worker node on a second Windows host.

.DESCRIPTION
    - Clones the ubisoft/exo repo (supportWindows branch)
    - Installs Python dependencies via uv
    - Builds the dashboard
    - Downloads llama.cpp b7836 CUDA binaries
    - Creates a startup script

    NOTE: Does NOT require admin rights.
    Run configure-firewall.ps1 as Administrator separately to open ports.

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
    .\install-worker.ps1 -InstallDir D:\exo -NoApi -CudaVersion 12.2
#>
param(
    [string]$InstallDir   = "C:\exo",
    [switch]$NoApi,
    [switch]$SkipDashboard,
    [string]$CudaVersion  = "12.4"
)

Set-StrictMode -Version Latest
# Do NOT set ErrorActionPreference=Stop globally — PS 5.1 treats any native
# command stderr as a terminating error. Check $LASTEXITCODE after key steps.

$LlamaBuild   = "b7836"
$LlamaZip     = "llama-$LlamaBuild-bin-win-cuda-$CudaVersion-x64.zip"
# Also need the cudart runtime package alongside the main zip
$CudartZip    = "cudart-llama-bin-win-cuda-$CudaVersion-x64.zip"
$LlamaUrl     = "https://github.com/ggerganov/llama.cpp/releases/download/$LlamaBuild/$LlamaZip"
$RepoUrl      = "https://github.com/ubisoft/exo.git"
$Branch       = "supportWindows"
$LibP2PPort   = 4001
$ApiPort      = 52415

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Assert-Command([string]$cmd, [string]$install) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] '$cmd' not found. $install" -ForegroundColor Red
        exit 1
    }
}

# --- prerequisite checks ---

Write-Step "Checking prerequisites"

Assert-Command "git" "Install Git: winget install Git.Git"

if (-not (Get-Command "uv" -ErrorAction SilentlyContinue)) {
    Write-Host "  uv not found - installing via winget..."
    winget install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] uv install failed" -ForegroundColor Red; exit 1 }
    # Reload PATH so uv is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    Assert-Command "uv" "Restart PowerShell and re-run this script."
}

$pyVer = uv python find 2>&1
Write-Host "  Python : $pyVer"
Write-Host "  uv     : $(uv --version)"
Write-Host "  git    : $(git --version)"

if (-not (Get-Command "npm" -ErrorAction SilentlyContinue) -and -not $SkipDashboard) {
    Write-Host "[WARN] npm not found - dashboard build will be skipped." -ForegroundColor Yellow
    $SkipDashboard = $true
}

# --- clone ---

Write-Step "Cloning repository into $InstallDir"

if (Test-Path "$InstallDir\.git") {
    Write-Host "  Directory exists - pulling latest changes"
    git -C $InstallDir fetch origin
    git -C $InstallDir checkout $Branch
    git -C $InstallDir pull origin $Branch
} else {
    git clone --branch $Branch $RepoUrl $InstallDir
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] git clone failed" -ForegroundColor Red; exit 1 }
}

Set-Location $InstallDir

# --- python deps ---

Write-Step "Installing Python dependencies"
$env:UV_SKIP_WHEEL_FILENAME_CHECK = "1"
uv sync
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] uv sync failed" -ForegroundColor Red; exit 1 }

# --- dashboard ---

if (-not $SkipDashboard) {
    Write-Step "Building dashboard"
    Push-Location "$InstallDir\dashboard"
    npm install
    npm run build
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] dashboard build failed" -ForegroundColor Red; exit 1 }
    Pop-Location
}

# --- llama.cpp binaries ---

Write-Step "Downloading llama.cpp $LlamaBuild ($CudaVersion)"

$tmpZip     = "$env:TEMP\$LlamaZip"
$tmpCudart  = "$env:TEMP\$CudartZip"
$tmpDir     = "$env:TEMP\llama-extract"

if (-not (Test-Path $tmpZip)) {
    Write-Host "  Downloading $LlamaZip"
    Invoke-WebRequest -Uri $LlamaUrl -OutFile $tmpZip -UseBasicParsing
} else {
    Write-Host "  Main archive already cached"
}

$CudartUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$LlamaBuild/$CudartZip"
if (-not (Test-Path $tmpCudart)) {
    Write-Host "  Downloading $CudartZip"
    Invoke-WebRequest -Uri $CudartUrl -OutFile $tmpCudart -UseBasicParsing
} else {
    Write-Host "  Cudart archive already cached"
}

Write-Host "  Extracting..."
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
Expand-Archive -Path $tmpZip    -DestinationPath $tmpDir
Expand-Archive -Path $tmpCudart -DestinationPath $tmpDir -Force

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

# --- startup script ---

Write-Step "Writing startup script"

$exoArgs = if ($NoApi) { "--no-api" } else { "" }
$startScript = @"
# exo worker startup script - generated by install-worker.ps1
Set-Location "$InstallDir"

`$env:UV_SKIP_WHEEL_FILENAME_CHECK = "1"
`$env:EXO_LLAMA_SERVER_PATH        = "$InstallDir\llama-server.exe"
`$env:EXO_LIBP2P_LISTEN_PORT       = "$LibP2PPort"
`$env:EXO_LIBP2P_LISTEN_ADDR       = "0.0.0.0"

uv run exo $exoArgs
"@

$startPath = "$InstallDir\start-exo.ps1"
Set-Content -Path $startPath -Value $startScript.Trim() -Encoding UTF8
Write-Host "  Written to $startPath"

# --- done ---

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host "  Next step - open firewall ports (requires Admin):" -ForegroundColor Green
Write-Host "    Right-click configure-firewall.ps1 > Run as Administrator" -ForegroundColor Green
Write-Host "    (script is at $InstallDir\scripts\configure-firewall.ps1)" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host "  Then start exo:" -ForegroundColor Green
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$startPath`"" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
