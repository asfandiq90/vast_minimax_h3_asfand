#!/usr/bin/env bash
# Vast.ai ComfyUI provisioning script. Run with bash, not sh.
set -Eeuo pipefail
umask 022
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE:-/workspace}/ComfyUI}"
[[ -f "$COMFYUI_DIR/main.py" ]] || {
    echo "ComfyUI not found at $COMFYUI_DIR; set COMFYUI_DIR to its install path." >&2
    exit 1
}
mkdir -p "$COMFYUI_DIR/setup-logs"
exec > >(tee -a "$COMFYUI_DIR/setup-logs/minimax-h3.log") 2>&1
trap 'echo "Setup failed at line $LINENO. Fix the error above and rerun; downloads can resume." >&2' ERR
echo "Starting MiniMax H3 setup: $(date -Is)"

if ! command -v aria2c >/dev/null || ! command -v curl >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y aria2 curl ca-certificates
fi

# Use the interpreter belonging to ComfyUI, never an arbitrary system pip.
if [[ -z "${COMFYUI_PYTHON:-}" ]]; then
    for candidate in "$COMFYUI_DIR/.venv/bin/python" "$COMFYUI_DIR/venv/bin/python" /venv/main/bin/python; do
        if [[ -x "$candidate" ]]; then
            COMFYUI_PYTHON="$candidate"
            break
        fi
    done
fi
[[ -n "${COMFYUI_PYTHON:-}" && -x "$COMFYUI_PYTHON" ]] || {
    echo 'Set COMFYUI_PYTHON to the Python executable used by your ComfyUI service.' >&2
    exit 1
}

download_model() {
    local relative_dir="$1" name="$2" url="$3"
    local target_dir="$COMFYUI_DIR/$relative_dir"
    mkdir -p "$target_dir"
    if [[ -s "$target_dir/$name" && ! -e "$target_dir/$name.aria2" ]]; then
        echo "Already present: $name"
        return
    fi
    echo "Downloading: $name"
    # New downloads stay under a temporary name until aria2 reports success.
    # Existing partial files made by your original commands are resumed in place.
    local output="$name.partial"
    if [[ -e "$target_dir/$name.aria2" ]]; then output="$name"; fi
    aria2c --continue=true --auto-file-renaming=false --allow-overwrite=true \
        --max-tries=10 --retry-wait=10 --connect-timeout=30 --timeout=60 \
        -x 16 -s 16 -d "$target_dir" -o "$output" "$url"
    [[ -s "$target_dir/$output" ]]
    if [[ "$output" != "$name" ]]; then mv -- "$target_dir/$output" "$target_dir/$name"; fi
}

# Download exactly the model filenames and destinations from your command list.
download_model models/diffusion_models minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors 'https://huggingface.co/smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models/resolve/main/minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors?download=true'
download_model models/text_encoders qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors 'https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors?download=true'
download_model models/vae minimax_h3_video_vae_fp16.safetensors 'https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors?download=true'
download_model models/vae minimax_h3_audio_vae_fp32.safetensors 'https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors?download=true'
download_model 'models/loras/minimax h3' minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors 'https://huggingface.co/Kijai/MiniMax-H3-experimental/resolve/main/loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors?download=true'
download_model 'models/loras/minimax h3' minimax-h3-people.safetensors 'https://huggingface.co/RunningHubAI/rh-minimax-h3-lora/resolve/main/minimax-h3-people.safetensors?download=true'
download_model models/loras minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors 'https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors?download=true'
download_model models/loras minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors 'https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors?download=true'
download_model models/loras minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors 'https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors?download=true'
download_model models/vae_approx taeh3.safetensors 'https://huggingface.co/Kijai/MiniMax-H3-TAE/resolve/main/vae_approx/taeh3.safetensors?download=true'
download_model models/latent_upscale_models minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors 'https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler/resolve/main/minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors?download=true'

# Download each custom node once; install requirements in ComfyUI's environment.
# A completion marker is only written after dependency installation succeeds.
install_node() {
    local name="$1" url="$2" dest="$COMFYUI_DIR/custom_nodes/$1"
    if [[ -f "$dest/.minimax-setup-complete" ]]; then
        echo "Already installed: $name"
        return
    fi
    if [[ ! -f "$dest/__init__.py" ]]; then
        if [[ -d "$dest" && -n "$(ls -A "$dest")" ]]; then
            echo "Existing incomplete node folder: $dest. Inspect it before retrying." >&2
            return 1
        fi
        local staging
        staging="$(mktemp -d "$COMFYUI_DIR/custom_nodes/.install-XXXXXX")"
        curl --fail --location --retry 5 --connect-timeout 30 \
            "$url" -o "$staging/source.tar.gz"
        mkdir -p "$staging/node"
        tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/node"
        [[ -f "$staging/node/__init__.py" ]]
        mkdir -p "$dest"
        cp -a "$staging/node/." "$dest/"
        # Only this temporary directory created above is removed.
        rm -rf -- "$staging"
    fi
    if [[ -f "$dest/requirements.txt" ]]; then
        "$COMFYUI_PYTHON" -m pip install -r "$dest/requirements.txt"
    fi
    touch "$dest/.minimax-setup-complete"
}
mkdir -p "$COMFYUI_DIR/custom_nodes"
install_node comfyui-obvpm https://codeload.github.com/chanon/comfyui-obvpm/tar.gz/refs/heads/main
install_node comfyui-obvpm-timeline https://codeload.github.com/chanon/comfyui-obvpm-timeline/tar.gz/refs/heads/main
install_node comfyui_minimax_h3_latent_upscaler https://codeload.github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler/tar.gz/refs/heads/main
install_node comfyui-spectrum-minimax-h3 https://codeload.github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3/tar.gz/refs/heads/main
install_node ComfyUI-MiniMax-H3-Turbo-main https://codeload.github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo/tar.gz/refs/heads/main

echo "MiniMax H3 models and nodes installed: $(date -Is)"
echo "If ComfyUI was already running, restart its service to load the custom nodes."
