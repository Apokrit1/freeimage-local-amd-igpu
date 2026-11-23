#!/usr/bin/env bash
# freeimage-local installer
# Builds stable-diffusion.cpp for your machine and downloads Z-Image Turbo (int8).
#
#   ./install.sh            build + download everything
#   ./install.sh --build    only (re)build the engine
#   ./install.sh --models   only download / verify the models
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"

# stable-diffusion.cpp version this repo is tested against. Override with SDCPP_REF=master.
SDCPP_REPO="https://github.com/leejet/stable-diffusion.cpp.git"
SDCPP_REF="${SDCPP_REF:-532d2c15c430a785a712b2d94281f04e733008a4}"

# name | url | sha256 | bytes
MODEL_DIFFUSION="diffusion|https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/diffusion_models/z_image_turbo_int8_convrot.safetensors|be517ebd47c912a5626a588e1aeea43e6be4a43c0cdcd2b48a2a780d9f358635|6201001296"
MODEL_TE_Q8="text-encoder (Q8_0)|https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q8_0.gguf|eed555233267a33c7e8ee31682762cc7751b3f6d224039086e0e846f05fffa5d|4280405792"
MODEL_TE_Q4="text-encoder (Q4_K_M · 16 GB iGPU)|https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf|f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a|0"
MODEL_VAE="vae|https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/vae/ae.safetensors|afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38|335304388"

need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1'. $2"; }

build_engine() {
  step "Checking your machine"
  detect_platform
  info "platform: $FI_PLATFORM ($FI_DEVICE)"

  need git "Install git first."
  need cmake "macOS: brew install cmake   ·   Ubuntu: sudo apt install cmake"
  local gen=()
  command -v ninja >/dev/null 2>&1 && gen=(-G Ninja)

  local flags=(-DCMAKE_BUILD_TYPE=Release)
  case "$FI_PLATFORM" in
    metal)
      flags+=(-DSD_METAL=ON)
      ;;
    cuda)
      need nvcc "Install the CUDA toolkit (12.8+ for RTX 50-series): https://developer.nvidia.com/cuda-downloads"
      local cuda_ver; cuda_ver="$(nvcc --version | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')"
      info "CUDA toolkit: $cuda_ver, GPU architecture: sm_$FI_CUDA_ARCH"
      if [ "$FI_CUDA_ARCH" -ge 120 ] && ! version_ge "$cuda_ver" 12.8; then
        die "RTX 50-series (sm_120) needs CUDA 12.8 or newer; you have $cuda_ver."
      fi
      flags+=(-DSD_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=$FI_CUDA_ARCH")
      # Older CUDA releases reject the newest gcc. Use the newest supported g++ if one is installed.
      for v in 14 13 12; do
        if command -v "g++-$v" >/dev/null 2>&1; then
          flags+=("-DCMAKE_CUDA_HOST_COMPILER=$(command -v "g++-$v")"); break
        fi
      done
      ;;
    vulkan)
      flags+=(-DSD_VULKAN=ON)
      ;;
    rocm)
      flags+=(-DSD_HIPBLAS=ON)
      ;;
    *)
      die "No supported GPU found. freeimage-local needs an AMD iGPU/GPU (Vulkan/ROCm), Apple Silicon Mac, or NVIDIA RTX GPU."
      ;;
  esac

  step "Getting stable-diffusion.cpp ($SDCPP_REF)"
  local src="$FI_HOME/src/stable-diffusion.cpp"
  if [ ! -d "$src/.git" ]; then
    git clone --quiet "$SDCPP_REPO" "$src"
  fi
  git -C "$src" fetch --quiet origin
  git -C "$src" checkout --quiet "$SDCPP_REF" 2>/dev/null || git -C "$src" checkout --quiet "origin/$SDCPP_REF"
  git -C "$src" submodule update --init --recursive --quiet
  info "at $(git -C "$src" rev-parse --short HEAD)"

  step "Building (a few minutes; CUDA builds take longer)"
  cmake -S "$src" -B "$src/build" "${gen[@]}" "${flags[@]}" >"$FI_HOME/build.log" 2>&1 \
    || { tail -30 "$FI_HOME/build.log"; die "cmake configure failed. Full log: $FI_HOME/build.log"; }
  cmake --build "$src/build" --config Release -j "$(cpu_count)" --target sd-cli sd-server >>"$FI_HOME/build.log" 2>&1 \
    || { tail -30 "$FI_HOME/build.log"; die "build failed. Full log: $FI_HOME/build.log"; }
  mkdir -p "$FI_HOME/bin"
  cp "$src/build/bin/sd-cli" "$src/build/bin/sd-server" "$FI_HOME/bin/"
  printf '%s\n' "$FI_PLATFORM" >"$FI_HOME/platform"
  ok "engine ready: $FI_HOME/bin"
}

download_models() {
  detect_platform
  local te_entry="$MODEL_TE_Q8"
  if [ "${FI_LLM_QUANT:-}" != q8 ] && { [ "$FI_IS_IGPU" = 1 ] || [ "$FI_RAM_GB" -le 18 ] || [ "${FI_LLM_QUANT:-}" = q4 ]; }; then
    te_entry="$MODEL_TE_Q4"
    step "Downloading models (~9.0 GB for 16 GB AMD iGPU, resumable)"
  else
    step "Downloading models (~10.8 GB, resumable)"
  fi
  local models=("$MODEL_DIFFUSION" "$te_entry" "$MODEL_VAE")
  need curl "Install curl first."
  mkdir -p "$FI_HOME/models"
  local entry name url sha bytes file
  for entry in "${models[@]}"; do
    IFS='|' read -r name url sha bytes <<<"$entry"
    file="$FI_HOME/models/$(basename "$url")"
    if [ -f "$file" ] && [ "$bytes" != 0 ] && [ "$(file_size "$file")" = "$bytes" ]; then
      info "$name: already downloaded"
    elif [ -f "$file" ] && [ "$bytes" = 0 ] && [ "$(sha256 "$file")" = "$sha" ]; then
      info "$name: already downloaded"
    else
      local size_label=""
      [ "$bytes" != 0 ] && size_label=" ($(human "$bytes"))"
      info "$name: $(basename "$url")$size_label"
      curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$file" "$url" \
        || die "download failed for $name. Run ./install.sh --models again to resume."
    fi
    if [ "${FI_SKIP_VERIFY:-0}" != 1 ]; then
      printf '  verifying… '
      [ "$(sha256 "$file")" = "$sha" ] || { echo; die "$name checksum mismatch. Delete $file and run ./install.sh --models"; }
      echo ok
    fi
  done
  ok "models ready: $FI_HOME/models"
}

case "${1:-all}" in
  --build)  build_engine ;;
  --models) download_models ;;
  all|"")   build_engine; download_models ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

if [ "${1:-all}" = all ]; then
  echo
  ok "All set. Try:"
  echo "    ./fi \"a red fox in fresh snow, golden hour\""
  echo "    ./fi serve        # web UI on http://localhost:7861"
fi
