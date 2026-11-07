# ============================================================
#  Avalon + Qwen3.8-Flash-Next setup - Windows + RTX 3090
#  Checks prereqs, clones + builds Avalon, downloads models with
#  SHA256 verification, quantizes the vision mmproj to Q8_0.
#
#  Usage:  .\setup.ps1              (full setup)
#          .\setup.ps1 -SkipBuild   (models only)
#          .\setup.ps1 -SkipDownload (build only)
#
#  Safe to re-run: completed downloads and the build are skipped.
# ============================================================
param(
    [switch]$SkipBuild,
    [switch]$SkipDownload
)

# Native tools (git/cmake/curl) write progress to stderr; do not use 'Stop' here.
$ErrorActionPreference = 'Continue'

$Root      = $PSScriptRoot
$SrcDir    = Join-Path $Root 'Avalon'
$BuildDir  = 'build_cuda'
$BinDir    = Join-Path (Join-Path $SrcDir $BuildDir) 'bin'
$ModelsDir = Join-Path $Root 'models'
$Arch      = '86'   # RTX 3090 = Ampere sm_86

$RepoURL   = 'https://github.com/Kobodera/Avalon3090.git'   # fork of freriadoc/Avalon (see README)
$HFModel   = 'https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF/resolve/main'
$HFMMProj  = 'https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/mmproj-BF16.gguf'

function Write-Step($msg)  { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "[skip] $msg" -ForegroundColor DarkGray }

# ------------------------------------------------------------
# 1. Prerequisites
# ------------------------------------------------------------
Write-Step 'Checking prerequisites'
$missing = @()

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missing += 'git (install https://git-scm.com/download/win)'
} else { Write-Ok "git: $((git --version) -join '')" }

if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    $missing += 'nvidia-smi (install NVIDIA GPU driver)'
} else {
    $gpu = (nvidia-smi --query-gpu=name,memory.total --format=csv,noheader) -join ''
    Write-Ok "GPU: $gpu"
}

# VS Build Tools with VC++ x64
$VSWHERE = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VSROOT = $null
if (Test-Path $VSWHERE) {
    $VSROOT = & $VSWHERE -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if ($VSROOT) { Write-Ok "VS: $VSROOT" } else { $missing += 'Visual Studio Build Tools with Desktop C++ workload' }

# CUDA toolkit: pick newest install under the standard path
$cudaRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\'
$CUDA_BIN = $null
if (Test-Path $cudaRoot) {
    $CUDA_BIN = Get-ChildItem $cudaRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\nvcc.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'bin' }
}
if ($CUDA_BIN) { Write-Ok "CUDA: $CUDA_BIN" } else { $missing += 'NVIDIA CUDA Toolkit (https://developer.nvidia.com/cuda-downloads)' }

# cmake / ninja: use PATH, else offer winget install
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
$ninja = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $cmake -or -not $ninja) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (-not $cmake) { Write-Host 'Installing cmake via winget...'; winget install -e --accept-source-agreements --accept-package-agreements Kitware.CMake | Out-Null }
        if (-not $ninja) { Write-Host 'Installing ninja via winget...'; winget install -e --accept-source-agreements --accept-package-agreements Ninja-build.Ninja | Out-Null }
        # winget installs land in a new PATH; re-resolve common locations
        $cmakeDir = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter 'Kitware.CMake*' |
            ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter cmake.exe -ErrorAction SilentlyContinue } |
            Select-Object -First 1 -ExpandProperty DirectoryName
        $ninjaDir = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter 'Ninja-build.Ninja*' |
            Select-Object -First 1 -ExpandProperty FullName
        if ($cmakeDir) { $env:PATH = "$cmakeDir;$env:PATH" }
        if ($ninjaDir)  { $env:PATH = "$ninjaDir;$env:PATH" }
        $cmake = Get-Command cmake -ErrorAction SilentlyContinue
        $ninja = Get-Command ninja -ErrorAction SilentlyContinue
    }
}
if ($cmake) { Write-Ok "cmake: $($cmake.Source)" } else { $missing += 'cmake (winget install Kitware.CMake)' }
if ($ninja) { Write-Ok "ninja: $($ninja.Source)" } else { $missing += 'ninja (winget install Ninja-build.Ninja)' }

if ($missing.Count -gt 0) {
    Write-Host "`nMissing prerequisites:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host 'Install the above, then re-run setup.ps1.'
    exit 1
}
Write-Ok 'All prerequisites present'

# ------------------------------------------------------------
# 2. Clone Avalon run fork
# ------------------------------------------------------------
if (-not $SkipDownload -or -not (Test-Path $SrcDir)) {
    Write-Step 'Cloning Avalon (run fork of freriadoc/Avalon)'
    if (Test-Path (Join-Path $SrcDir '.git')) {
        Write-Skip 'Avalon already cloned'
    } else {
        git clone $RepoURL $SrcDir
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
        Write-Ok "Cloned to $SrcDir"
    }
}

# ------------------------------------------------------------
# 3. Build (llama-server, llama-mtmd-cli, llama-quantize)
# ------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step "Building Avalon for CUDA sm_$Arch"

    # Import MSVC x64 dev environment into this session
    $vcvars = Join-Path $VSROOT 'VC\Auxiliary\Build\vcvars64.bat'
    $envDump = cmd /c "`"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') { Set-Item -Force -Path "env:$($matches[1])" -Value $matches[2] }
    }

    Push-Location $SrcDir
    try {
        & cmake -B $BuildDir -G Ninja `
            -DGGML_CUDA=ON `
            -DCMAKE_CUDA_ARCHITECTURES=$Arch `
            -DCMAKE_BUILD_TYPE=Release `
            -DLLAMA_BUILD_TOOLS=ON `
            -DGGML_CUDA_GRAPHS=ON `
            -DGGML_CUDA_NCCL=OFF
        if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }

        & cmake --build $BuildDir --target llama-server llama-mtmd-cli llama-quantize -j
        if ($LASTEXITCODE -ne 0) { throw 'build failed' }
    } finally {
        Pop-Location
    }
    Write-Ok "Built: $BinDir\llama-server.exe"
}

# ------------------------------------------------------------
# 4. Download models (resumable, SHA256 verified)
# ------------------------------------------------------------
function Get-VerifiedFile {
    param([string]$Url, [string]$Out, [long]$Size, [string]$Sha256)

    $name = Split-Path $Out -Leaf
    if ((Test-Path $Out) -and ((Get-Item $Out).Length -eq $Size)) {
        $h = (Get-FileHash $Out -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -eq $Sha256) { Write-Skip "$name (already verified)"; return }
    }
    Write-Host "[get ] $name ($([math]::Round($Size/1GB, 2)) GB)"
    # -C - resumes partial downloads; curl keeps .part progress on the final file
    & curl.exe -L -C - --retry 5 --retry-delay 3 -o $Out $Url
    if ($LASTEXITCODE -ne 0) { throw "download failed: $Url" }
    $h = (Get-FileHash $Out -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $Sha256) { throw "SHA256 MISMATCH for $name`n  expected: $Sha256`n  actual:   $h`n  Delete the file and re-run setup.ps1" }
    Write-Ok "$name verified"
}

if (-not $SkipDownload) {
    Write-Step 'Downloading model files (~90 GB, resumable)'
    New-Item -ItemType Directory -Force $ModelsDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $ModelsDir 'MTP') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $ModelsDir 'staging') | Out-Null

    $manifest = Get-Content (Join-Path $Root 'model_manifest.json') -Raw | ConvertFrom-Json
    foreach ($prop in $manifest.PSObject.Properties) {
        $rel  = $prop.Name
        $info = $prop.Value
        Get-VerifiedFile -Url "$HFModel/$rel" -Out (Join-Path $ModelsDir $rel) -Size $info.size -Sha256 $info.sha256
    }

    # Vision projector: BF16 from unsloth, quantized to Q8_0 locally.
    # NOTE: must be BF16, not F16. Q8_0(BF16) reproduces the validated projector's
    # weights byte-for-byte (334/334 tensors); Q8_0(F16) differs in 6 tensors.
    Write-Step 'Downloading + quantizing vision mmproj'
    $mmBF16 = Join-Path $ModelsDir 'staging\mmproj-BF16.gguf'
    Get-VerifiedFile -Url $HFMMProj -Out $mmBF16 -Size 907542944 `
        -Sha256 '2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355'

    $mmQ8 = Join-Path $ModelsDir 'mmproj-Qwen3.8-Flash-Next-Q8_0.gguf'
    if (-not (Test-Path $mmQ8)) {
        Write-Host '[quant] mmproj BF16 -> Q8_0'
        & (Join-Path $BinDir 'llama-quantize.exe') $mmBF16 $mmQ8 Q8_0
        if ($LASTEXITCODE -ne 0) { throw 'mmproj quantize failed' }
        $q8size = (Get-Item $mmQ8).Length
        if ($q8size -lt 616000000 -or $q8size -gt 617000000) {
            throw "mmproj Q8_0 size unexpected: $q8size (expected ~616.7 MB)"
        }
        Write-Ok "Created $mmQ8 ($q8size bytes)"
    } else {
        Write-Skip 'mmproj Q8_0 already present'
    }
}

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
Write-Step 'Setup complete'
Write-Host @"

Start the server:
    .\launch_vision_mtp.ps1

First boot takes ~2-4 min (model load + vision warmup).
Server listens on http://0.0.0.0:8080 (LAN, no API key - see README).

Verify:
    curl.exe http://localhost:8080/health
    .\vision_test.ps1
    .\churn_test.ps1
"@
