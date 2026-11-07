# Avalon + Qwen3.8-Flash-Next on Windows + RTX 3090

A validated **run recipe and setup automation** for [Avalon](https://github.com/freriadoc/Avalon)
(llama.cpp fork) + **Qwen3.8-Flash-Next** on a single **RTX 3090 (24 GB) + 64 GB RAM**
Windows box: MoE expert cache **ON**, **256k context** with compaction, **MTP** speculative
decoding and **vision** - served as an OpenAI-compatible `llama-server` on the LAN.

**No-nonsense reference.** The story of why this exists is in the run fork's README:
**[Kobodera/Avalon3090](https://github.com/Kobodera/Avalon3090)**. Avalon itself is
[freriadoc/Avalon](https://github.com/freriadoc/Avalon) - go there for what Avalon is,
its benchmarks, and its documentation. This page only covers running it on a 3090 under
Windows: setup, the memory recipe, and validated numbers.

## Requirements

- **OS:** Windows 10/11 x64
- **GPU:** RTX 3090 (24 GB). Should also work on other 24 GB+ Ampere cards
  (`-DCMAKE_CUDA_ARCHITECTURES=86` covers Ampere; adjust for your card)
- **RAM:** 64 GB (the model is ~88 GiB, it does not fit in RAM; the recipe relies on
  Windows virtual memory with `PIN=0`)
- **Disk:** ~120 GB free on an SSD/NVMe (model ~90 GB + build tree)
- **Software:**
  - [Git for Windows](https://git-scm.com/download/win)
  - Visual Studio Build Tools with "Desktop development with C++"
    ([download](https://visualstudio.microsoft.com/visual-cpp-build-tools/))
  - NVIDIA CUDA Toolkit (validated with **CUDA 13.4**; 12.x should also work)
  - CMake + Ninja (`setup.ps1` offers to install these via `winget` if missing)

No special pagefile configuration is needed. Windows' automatic pagefile management was
sufficient in all validated runs.

## Quick start (automatic)

This ops repo: **https://github.com/Kobodera/Avalon3090ops**

Open PowerShell in an empty folder and run:

```powershell
git clone https://github.com/Kobodera/Avalon3090ops.git
cd Avalon3090ops
.\setup.ps1
```

`setup.ps1` checks prerequisites, clones the run fork, builds it for CUDA sm_86,
downloads all model files (~90 GB, resumable, SHA256-verified against
`model_manifest.json`) and quantizes the vision projector. Re-running it after an
interrupted download is safe - completed steps are skipped.

Then launch the server:

```powershell
.\launch_vision_mtp.ps1
```

First boot takes ~2-4 min (model load + vision warmup). The server listens on
`http://0.0.0.0:8080` (LAN, no API key - see [Security](#security)).

Verify it:

```powershell
curl.exe http://localhost:8080/health
.\vision_test.ps1     # sends a PNG, expects OCR text back
.\churn_test.ps1      # IMG/CHAT/TOOLS mixed workload
```

## Manual install

If you'd rather do by hand what `setup.ps1` automates:

1. **Clone the run fork** (freriadoc/Avalon + the Windows fixes, see
   [Fork notes](#fork-notes)):

   ```powershell
   git clone https://github.com/Kobodera/Avalon3090.git
   cd Avalon
   ```

2. **Build** from a "x64 Native Tools Command Prompt" (or import `vcvars64.bat` first):

   ```
   cmake -B build_cuda -G Ninja -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86 ^
         -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TOOLS=ON -DGGML_CUDA_GRAPHS=ON -DGGML_CUDA_NCCL=OFF
   cmake --build build_cuda --target llama-server llama-mtmd-cli llama-quantize -j
   ```

3. **Download the model** from
   [freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)
   into a `models\` folder: the 33 `Qwen3.8-Flash-Next-Avalon-IQ3KS-*.gguf` shards,
   `moe-cache-ranking.bin` (must sit next to the model) and
   `MTP\mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf`.
   Verify every file against the sizes + SHA256 in this repo's `model_manifest.json`.

4. **Vision projector:** download `mmproj-BF16.gguf` from
   [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
   and quantize it:

   ```
   llama-quantize mmproj-BF16.gguf mmproj-Qwen3.8-Flash-Next-Q8_0.gguf Q8_0
   ```

   Use BF16, **not** F16: `Q8_0(BF16)` reproduces the validated projector's weights
   byte-for-byte (all 334 tensors hash-identical); `Q8_0(F16)` differs in 6 tensors.

5. **Set the memory recipe and launch** (see next section), e.g.:

   ```powershell
   $env:GGML_CUDA_MOE_CACHE_MODE = 'on'; $env:GGML_CUDA_MOE_PIN = '0'
   $env:GGML_CUDA_MOE_CACHE_BUDGET_MB = '12000'; $env:CUDA_MODULE_LOADING = 'EAGER'
   .\build_cuda\bin\llama-server.exe -m models\Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf `
     --model-draft models\MTP\mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf `
     --mmproj models\mmproj-Qwen3.8-Flash-Next-Q8_0.gguf --image-min-tokens 1024 `
     -c 262144 -b 9536 -ub 9536 -fa on -ctk q8_0 -ctv q4_0 --jinja --parallel 1 `
     --host 0.0.0.0 --port 8080
   ```

## The memory recipe (what actually matters)

Set by `launch_vision_mtp.ps1` before starting the server:

```powershell
$env:GGML_CUDA_MOE_CACHE_MODE      = 'on'    # Avalon hosted-expert cache
$env:GGML_CUDA_MOE_PIN             = '0'     # do NOT cudaHostRegister the weights
$env:GGML_CUDA_MOE_CACHE_BUDGET_MB = '12000'
$env:CUDA_MODULE_LOADING           = 'EAGER' # avoid lazy-load stalls mid-request
```

Why each one:

- **`MOE_CACHE_MODE=on`** - the whole point of Avalon: hot experts stay on GPU, cold
  experts stream from system RAM.
- **`MOE_PIN=0`** - the model (~88.3 GiB) is larger than 64 GB RAM. Pinning
  (`cudaHostRegister`) fails or thrashes at this ratio. Unpinned + Windows paging is the
  stable configuration.
- **`CACHE_BUDGET_MB=12000`** - 12 GB of on-GPU expert cache fits alongside KV cache in
  24 GB VRAM. If you hit VRAM pressure with vision + long commits, drop to `8000`.
- **`CUDA_MODULE_LOADING=EAGER`** - loads all CUDA kernels at startup instead of on first
  use, which avoids multi-second stalls inside live requests.
- **Never set `CUDA_LAUNCH_BLOCKING=1`** - it is incompatible with Avalon's hosted MoE
  path and collapses throughput.

## Performance (validated)

Three modes, same box (RTX 3090, 64 GB DDR4, NVMe), same MoE cache recipe, driven by a
real multi-hour coding-agent workload through the full 246k-context + compaction lifecycle.

**Decoding (TG):**

| Mode | Median | Range | vs no-MTP |
|---|---|---|---|
| No MTP | 47.9 t/s | 28.5-58.7 (1,416 samples) | baseline |
| MTP | ~55-60 typical | floor 45, mid-run 55-84, peak ~100 | +15-70% by depth/content |
| MTP + vision | 52.2 t/s | p25 46.1 / p75 57.9 / max 84.2 | +9% |

MTP gain by depth: shallow ~57-58 (+20%), 46k code-heavy 67-76 (+40-58%), 100k
54.7-59.2 (+15-25%), near the 246k ceiling the draft cost eats most of the gain.

**Prompt processing (PP):**

| Mode | Peak (large warm jobs) | Compaction re-ingest |
|---|---|---|
| No MTP | 1,662 t/s | 1,660 t/s |
| MTP | 1,538 t/s | 1,342-1,380 t/s |
| MTP + vision | 1,000-1,476 t/s | 1,396 t/s |

MTP costs nothing on prefill - all modes hit the same warm-cache ceiling.

**Draft acceptance:** 0.40-0.96 across 201 samples through full 242.8k depth (text),
0.47-0.97 with vision churn. The old-build collapse signature (0.915 -> 0.000) never
reproduced on this build.

**Memory:**

| Mode | Commit plateau | Pagefile |
|---|---|---|
| No MTP | ~72 GB | default 4 GB, auto |
| MTP | ~106 GB | auto-grew to 43.9 GB (peak usage 4.9 GB) |
| MTP + vision | 112-115 GB | 64 GB alloc / 4.9 GB peak usage |

Compaction releases cleanly in every mode. If headroom gets tight, drop
`GGML_CUDA_MOE_CACHE_BUDGET_MB` to `8000`.

**Stability:** all three modes ran cold boot -> 242-246k deep tools churn -> compaction ->
re-prompt -> finish with zero wedges, zero gibberish, zero OOM. The MTP+vision config ran
5+ h continuous unattended with zero monitor warnings.

## Fork notes

The run fork [Kobodera/Avalon3090](https://github.com/Kobodera/Avalon3090) is
`freriadoc/Avalon` plus two local commits:

1. A stability base plate (build fixes for the current CUDA/MSVC toolchain + a port of
   upstream's MoE hosted deadlock fixes).
2. **Vision boot warmup**: at startup the server runs one synthetic 512x512 vision encode
   + decoder pass. This forces the WDDM/CUDA module set resident before the first real
   image and fixes a first-image deadlock seen on Windows. Cost: ~100 s of extra boot time.

If you build plain upstream `freriadoc/Avalon` instead, vision works but the **first
image request after boot can hang** on Windows. `setup.ps1` clones the fork by default.

## Troubleshooting

- **First image hangs / WDDM timeout** - make sure you built from the run fork (see
  [Fork notes](#fork-notes)); the boot warmup must be present.
- **Throughput collapse after long vision+commit sessions** - lower
  `GGML_CUDA_MOE_CACHE_BUDGET_MB` to `8000`.
- **`llama-server` writes normal logs to stderr and PowerShell shows red errors** -
  cosmetic. The launch scripts set `$ErrorActionPreference = 'Continue'` for this reason;
  do not set it to `Stop` around the server.
- **Setup script can't find CUDA** - check `C:\Program Files\NVIDIA GPU Computing
  Toolkit\CUDA\` exists and `nvcc --version` works in a plain cmd window.
- **SHA256 mismatch** - the file is corrupt; delete it and re-run `setup.ps1` (it will
  re-download just that file).

## Security

The server binds `0.0.0.0:8080` with **no API key** for LAN convenience. Do not expose
this to the internet. Put it behind an authenticating reverse proxy or bind to
`127.0.0.1` if you don't need LAN access.

## Credits and licenses

- **[Avalon](https://github.com/freriadoc/Avalon)** by [freriadoc](https://github.com/freriadoc) -
  the actual project this guide runs. MIT licensed. The run fork only carries the small
  Windows fixes described above; upstream remains the source of truth.
- **[ppkrol/Avalon_windows](https://github.com/ppkrol/Avalon_windows)** - earlier
  Windows port attempt, thank you for the groundwork.
- **[freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)** -
  the IQ3_KS quantization + MTP draft + expert ranking used here.
- **[unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)** -
  source of `mmproj-BF16.gguf` (quantized to Q8_0 locally by `setup.ps1`).
- **Qwen3.8-Flash-Next** base model by Alibaba Qwen, Qwen Community License.

Model weights are governed by their respective licenses (Qwen Community License 1.0 for
the model and mmproj; see the LICENSE in the HF repos). This repo contains only scripts.
