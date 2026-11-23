# shellcheck shell=bash disable=SC2034
# Shared helpers for install.sh and fi. Sourced, not executed.

FI_HOME="${FI_HOME:-$ROOT/.fi}"
mkdir -p "$FI_HOME"

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'; else B=; D=; G=; R=; N=; fi
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$N"; }
info() { printf '  %s%s%s\n' "$D" "$1" "$N"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$1"; }
die()  { printf '%s✗ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; }
file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB", u); i = 1; while (b >= 1024 && i < 4) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# Sets FI_PLATFORM (metal | cuda | vulkan | rocm | none), FI_DEVICE, FI_CUDA_ARCH, FI_VRAM_MB, FI_IS_IGPU, FI_RAM_GB.
detect_platform() {
  FI_PLATFORM=none; FI_DEVICE="no supported GPU"; FI_CUDA_ARCH=0; FI_VRAM_MB=0; FI_IS_IGPU=0; FI_RAM_GB=16
  if [ -r /proc/meminfo ]; then
    local kb; kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    [ -n "$kb" ] && FI_RAM_GB=$(( (kb + 524288) / 1048576 ))
  elif [ "$(uname -s)" = Darwin ]; then
    FI_RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  fi

  if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    FI_PLATFORM=metal
    FI_DEVICE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null), ${FI_RAM_GB} GB unified memory"
  elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    FI_PLATFORM=cuda
    local q; q="$(nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader,nounits | head -1)"
    FI_DEVICE="$(echo "$q" | cut -d, -f1 | sed 's/^ *//')"
    FI_CUDA_ARCH="$(echo "$q" | cut -d, -f2 | tr -d ' .')"
    FI_VRAM_MB="$(echo "$q" | cut -d, -f3 | tr -d ' ')"
    FI_DEVICE="$FI_DEVICE, $(( FI_VRAM_MB / 1024 )) GB VRAM"
  else
    # Check for AMD / Intel GPU or iGPU on Linux (lspci / vulkaninfo / /sys/class/drm)
    local gpu_line=""
    if command -v lspci >/dev/null 2>&1; then
      gpu_line="$(lspci 2>/dev/null | grep -iE 'VGA|Display|3D' | grep -iE 'AMD|ATI|Radeon|Intel' | head -1 | sed 's/^[^:]*:[^:]*: //')"
    fi
    if [ -z "$gpu_line" ] && command -v vulkaninfo >/dev/null 2>&1; then
      gpu_line="$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/ {gsub(/^ +/,"",$2); print $2; exit}')"
    fi
    if [ -n "$gpu_line" ] || [ -d /sys/class/drm/card0 ]; then
      FI_PLATFORM="${FI_BACKEND:-vulkan}"
      FI_IS_IGPU=1
      FI_DEVICE="${gpu_line:-AMD Radeon Graphics} (${FI_RAM_GB} GB shared RAM)"
    fi
  fi
}

# Pick Q4_K_M text encoder on <=18 GB iGPU setups (saves 1.8 GB RAM), Q8_0 otherwise.
llm_model_file() {
  local m="$FI_HOME/models"
  if [ "${FI_LLM_QUANT:-}" = q8 ] && [ -f "$m/Qwen3-4B-Q8_0.gguf" ]; then echo "$m/Qwen3-4B-Q8_0.gguf"; return; fi
  if [ "${FI_LLM_QUANT:-}" = q4 ] && [ -f "$m/Qwen3-4B-Q4_K_M.gguf" ]; then echo "$m/Qwen3-4B-Q4_K_M.gguf"; return; fi
  if [ "$FI_IS_IGPU" = 1 ] || [ "$FI_RAM_GB" -le 18 ]; then
    [ -f "$m/Qwen3-4B-Q4_K_M.gguf" ] && { echo "$m/Qwen3-4B-Q4_K_M.gguf"; return; }
    [ -f "$m/Qwen3-4B-Q8_0.gguf" ] && { echo "$m/Qwen3-4B-Q8_0.gguf"; return; }
    echo "$m/Qwen3-4B-Q4_K_M.gguf"
  else
    [ -f "$m/Qwen3-4B-Q8_0.gguf" ] && { echo "$m/Qwen3-4B-Q8_0.gguf"; return; }
    [ -f "$m/Qwen3-4B-Q4_K_M.gguf" ] && { echo "$m/Qwen3-4B-Q4_K_M.gguf"; return; }
    echo "$m/Qwen3-4B-Q8_0.gguf"
  fi
}

# Engine flags tuned per platform (see docs/how-it-works.md).
engine_args() {
  detect_platform
  local m="$FI_HOME/models"
  local llm; llm="$(llm_model_file)"
  FI_ARGS=(
    --diffusion-model "$m/z_image_turbo_int8_convrot.safetensors"
    --vae "$m/ae.safetensors"
    --llm "$llm"
    --cfg-scale 1.0
  )
  if [ "$FI_PLATFORM" = cuda ]; then
    FI_ARGS+=(--sage-attn)
    # int8 weights (6.2 GB) + text encoder (4.3 GB) only fit together on 12 GB+ cards.
    # Below that, weights live in RAM and stream into VRAM as needed.
    if [ "$FI_VRAM_MB" -lt 12000 ] || [ "${FI_OFFLOAD:-0}" = 1 ]; then FI_ARGS+=(--offload-to-cpu); fi
  elif [ "$FI_PLATFORM" = vulkan ] || [ "$FI_PLATFORM" = rocm ]; then
    FI_ARGS+=(--mmap --offload-to-cpu --flash-attn on --vae-tiling)
    local max_vram="${FI_MAX_VRAM:-3}"
    [ "$FI_RAM_GB" -gt 20 ] && [ -z "${FI_MAX_VRAM:-}" ] && max_vram=6
    [ "$max_vram" != 0 ] && FI_ARGS+=(--max-vram "$max_vram")
    [ "${FI_TE_CPU:-0}" = 1 ] && FI_ARGS+=(--backend te=cpu)
  fi
}

require_install() {
  [ -x "$FI_HOME/bin/sd-cli" ] || die "engine not built yet. Run ./install.sh"
  [ -f "$FI_HOME/models/z_image_turbo_int8_convrot.safetensors" ] || die "models missing. Run ./install.sh --models"
}
