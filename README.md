# Avalon + Qwen3.8-Flash-Next on Windows + RTX 3090

A validated **run guide and setup automation** for running [Avalon](https://github.com/freriadoc/Avalon)
(a llama.cpp fork) with **Qwen3.8-Flash-Next** on a single **RTX 3090 (24 GB VRAM) + 64 GB RAM**
Windows box, serving an OpenAI-compatible `llama-server` on the LAN with:

- MoE cache **ON** (Avalon's hosted-expert caching)
- **256k context** with compaction
- **MTP** speculative decoding (shared draft)
- **Vision** (mmproj image input)

> **Important:** I did **not** write Avalon. All credit for Avalon and its MoE caching goes to
> [freriadoc](https://github.com/freriadoc). This repo is just the Windows/3090 setup recipe,
> download scripts, and launch scripts that I validated end to end, plus a small Windows
> stability fix carried in the [run fork](https://github.com/Kobodera/Avalon3090)
> (see [Fork notes](#fork-notes)).

## Why this guide exists

Qwen3.8-Flash-Next is a ~90 GB MoE model. Fitting it on a 24 GB card with 64 GB system RAM
works, but only with the right memory recipe, and there are Windows-specific traps (WDDM
cold-load deadlocks, PowerShell stderr quirks). Everything here was validated with long
unattended runs before being written down.

**Validated result:** 246k-token session + compaction passed, 5 h unattended with zero
monitor warnings, TG median ~52 t/s, warm prompt processing 1,000-1,476 t/s, vision +
tools + MTP all working together.

## What's in this repo

| File | Purpose |
|---|---|
| `setup.ps1` | One-shot: prereq checks, clone + build Avalon, download models, quantize mmproj |
| `launch_vision_mtp.ps1` | Daily-driver launch script (MTP + vision + MoE cache recipe) |
| `model_manifest.json` | Exact file sizes + SHA256 for every downloaded model file |
| `vision_test.ps1` | Post-install gate: OCR a PNG through the server |
| `churn_test.ps1` | Post-install gate: IMG/CHAT/TOOLS churn loop |

## Requirements

- **OS:** Windows 10/11 x64
- **GPU:** RTX 3090 (24 GB). Should also work on other 24 GB+ Ampere/Ada cards
  (`-DCMAKE_CUDA_ARCHITECTURES=86` covers Ampere; adjust for your card)
- **RAM:** 64 GB (the model is ~88 GiB, it does not fit in RAM; the recipe relies on
  Windows virtual memory with `PIN=0`)
- **Disk:** ~120 GB free on an SSD/NVMe (model ~90 GB + build tree)
- **Software:**
  - [Git for Windows](https://git-scm.com/download/win)
  - Visual Studio Build Tools with "Desktop development with C++"
    ([download](https://visualstudio.microsoft.com/visual-cpp-build-tools/))
  - NVIDIA CUDA Toolkit (this guide was validated with **CUDA 13.4**; 12.x should also work)
  - CMake + Ninja (`setup.ps1` offers to install these via `winget` if missing)

No special pagefile configuration is needed. Windows' automatic pagefile management was
sufficient in the validated runs.

## Quick start

Open PowerShell in an empty folder and run:

```powershell
git clone https://github.com/Kobodera/Avalon3090ops.git
cd Avalon3090ops
.\setup.ps1
```

`setup.ps1` will:

1. Check prerequisites (git, VS Build Tools, CUDA, cmake, ninja) and report anything missing.
2. Clone the Avalon run fork (`Kobodera/Avalon3090`, based on `freriadoc/Avalon`).
3. Build `llama-server`, `llama-mtmd-cli`, `llama-quantize` with CUDA for sm_86.
4. Download the model files from Hugging Face with resume support and verify every
   SHA256 against `model_manifest.json`:
   - 33 x `Qwen3.8-Flash-Next-Avalon-IQ3KS-*.gguf` shards (~88 GB) from
     [freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)
   - `moe-cache-ranking.bin` (Avalon's expert ranking, loaded from next to the model)
   - `MTP/mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf` (MTP draft)
5. Download `mmproj-BF16.gguf` from
   [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
   and quantize it to Q8_0 with the freshly built `llama-quantize`. This reproduces the
   validated vision projector's weights byte-for-byte (all 334 tensors hash-identical).
   Use BF16, **not** F16: `Q8_0(F16)` differs in 6 tensors and is not the validated file.

Downloads are resumable (curl `-C -`) and verified files are skipped on re-run, so you can
safely re-run `setup.ps1` after an interrupted download.

Then launch the server:

```powershell
.\launch_vision_mtp.ps1
```

First boot takes ~2-4 min (model load + vision warmup). After that the server listens on
`http://0.0.0.0:8080` (LAN, no API key - see [Security](#security)).

Verify it:

```powershell
curl.exe http://localhost:8080/health
.\vision_test.ps1     # sends a PNG, expects OCR text back
.\churn_test.ps1      # IMG/CHAT/TOOLS mixed workload
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

## Launch parameters

From `launch_vision_mtp.ps1`:

```
-c 262144            256k context
-b 9536 -ub 9536     batch/ubatch tuned for this memory layout
-fa on -ctk q8_0 -ctv q4_0   flash attention + quantized KV (fits 256k in VRAM)
--jinja              model chat template
--parallel 1         single slot (this box is one heavy user)
--image-min-tokens 1024
--model-draft ...    MTP shared draft for speculative decoding
--mmproj ...         vision projector
```

## Performance (validated)

Measured on the reference box (RTX 3090, 64 GB DDR4, NVMe):

| Metric | Value |
|---|---|
| Generation (TG, MTP on) | median ~52 t/s |
| Prompt processing (warm) | 1,000 - 1,476 t/s |
| Context | 262,144 with compaction, passed at 246k used |
| Unattended stability | 5 h soak, zero warnings |
| First boot | ~2-4 min (includes vision warmup) |

## Fork notes

The run fork [Kobodera/Avalon3090](https://github.com/Kobodera/Avalon3090) is
`freriadoc/Avalon` plus two local commits:

1. A stability base plate (build fixes for the current CUDA/MSVC toolchain).
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
- **[freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)** -
  the IQ3_KS quantization + MTP draft + expert ranking used here.
- **[unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)** -
  source of `mmproj-BF16.gguf` (quantized to Q8_0 locally by `setup.ps1`).
- **Qwen3.8-Flash-Next** base model by Alibaba Qwen, Qwen Community License.

Model weights are governed by their respective licenses (Qwen Community License 1.0 for the
model and mmproj; see the LICENSE in the HF repos). This repo contains only scripts.
