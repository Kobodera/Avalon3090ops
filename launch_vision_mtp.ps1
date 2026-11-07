# Launch Avalon with the validated memory recipe + MTP draft + VISION (mmproj).
# Paths are relative to this script's folder (the ops repo root).
# Vision warmup is ON by default (GGML_CUDA_MOE_VISION_WARMUP / _DECODER_WARMUP):
# boot costs ~100s extra, first image is fast and avoids the WDDM cold-load cycle.
# NOTE: ErrorActionPreference must NOT be 'Stop' here - llama-server writes
# normal log lines to stderr, which PowerShell turns into terminating errors.
$ErrorActionPreference = 'Continue'

# --- memory recipe (identical to the proven cache-ON run) ---
$env:GGML_CUDA_MOE_CACHE_MODE      = 'on'
$env:GGML_CUDA_MOE_PIN             = '0'
$env:GGML_CUDA_MOE_CACHE_BUDGET_MB = '12000'
$env:CUDA_MODULE_LOADING           = 'EAGER'
# NOT setting CUDA_LAUNCH_BLOCKING (incompatible with hosted MoE)

$Root   = $PSScriptRoot
$exe    = Join-Path $Root 'Avalon\build_cuda\bin\llama-server.exe'
$model  = Join-Path $Root 'models\Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf'
$draft  = Join-Path $Root 'models\MTP\mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf'
$mmproj = Join-Path $Root 'models\mmproj-Qwen3.8-Flash-Next-Q8_0.gguf'

foreach ($f in @($exe, $model, $draft, $mmproj)) {
    if (-not (Test-Path $f)) { throw "missing file: $f (run .\setup.ps1 first)" }
}

Write-Output ("launching WITH MTP + VISION: {0}" -f $exe)
& $exe -m $model `
  --model-draft $draft `
  --mmproj $mmproj --image-min-tokens 1024 `
  -c 262144 -b 9536 -ub 9536 -fa on -ctk q8_0 -ctv q4_0 --jinja --parallel 1 `
  --host 0.0.0.0 --port 8080
