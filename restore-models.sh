#!/usr/bin/env bash
# Run this script on a RunPod pod with the network volume mounted at /workspace.
# It downloads all models that chara2img-api expects and places them in the
# correct subfolders so the serverless worker can use them via symlinks.
#
# Usage:
#   chmod +x restore-models.sh
#   CIVITAI_API_KEY=your_key ./restore-models.sh
#
# Optional env vars:
#   MODELS_ROOT   — destination root (default: /workspace/models)
#   CIVITAI_API_KEY — required for the CivitAI model

set -euo pipefail

MODELS_ROOT="${MODELS_ROOT:-/workspace/models}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# Prefer wget, fall back to curl
download() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    ok "Already exists: $(basename "$dest") — skipping"
    return 0
  fi
  info "Downloading $(basename "$dest") …"
  local tmp="${dest}.part"
  if command -v wget &>/dev/null; then
    wget -q --show-progress -O "$tmp" "$url"
  elif command -v curl &>/dev/null; then
    curl -fL --progress-bar -o "$tmp" "$url"
  else
    die "Neither wget nor curl found"
  fi
  mv "$tmp" "$dest"
  ok "Saved: $dest"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if [[ -z "${CIVITAI_API_KEY:-}" ]]; then
  warn "CIVITAI_API_KEY is not set — the CivitAI model will be skipped."
  warn "Re-run with: CIVITAI_API_KEY=your_key ./restore-models.sh"
fi

info "Models root: $MODELS_ROOT"

# ─── Create directories ───────────────────────────────────────────────────────

mkdir -p \
  "$MODELS_ROOT/checkpoints" \
  "$MODELS_ROOT/vae" \
  "$MODELS_ROOT/loras" \
  "$MODELS_ROOT/upscale_models" \
  "$MODELS_ROOT/ultralytics/segm" \
  "$MODELS_ROOT/ultralytics/bbox"

# ─── Checkpoint ───────────────────────────────────────────────────────────────

download \
  "https://huggingface.co/Ine007/waiIllustriousSDXL_v160/resolve/main/waiIllustriousSDXL_v160.safetensors" \
  "$MODELS_ROOT/checkpoints/waiIllustriousSDXL_v160.safetensors"

# ─── VAE ─────────────────────────────────────────────────────────────────────

download \
  "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors" \
  "$MODELS_ROOT/vae/sdxl_vae.safetensors"

# ─── Upscaler ────────────────────────────────────────────────────────────────

download \
  "https://huggingface.co/MIUProject/VNCCS/resolve/main/models/upscale_models/4x_APISR_GRL_GAN_generator.pth" \
  "$MODELS_ROOT/upscale_models/4x_APISR_GRL_GAN_generator.pth"

# ─── LoRAs ───────────────────────────────────────────────────────────────────

download \
  "https://huggingface.co/tglink/Houtengeki-Style-IL/resolve/main/Houtengeki_Style.safetensors" \
  "$MODELS_ROOT/loras/Houtengeki_Style.safetensors"

if [[ -n "${CIVITAI_API_KEY:-}" ]]; then
  download \
    "https://civitai.com/api/download/models/1258256?token=${CIVITAI_API_KEY}" \
    "$MODELS_ROOT/loras/na_tarapisu153rapisu_Style.safetensors"
fi

# ─── YOLOv8 detection models ──────────────────────────────────────────────────

download \
  "https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt" \
  "$MODELS_ROOT/ultralytics/segm/person_yolov8m-seg.pt"

download \
  "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt" \
  "$MODELS_ROOT/ultralytics/bbox/face_yolov8m.pt"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
ok "Done. Model tree:"
find "$MODELS_ROOT" -type f | sort | sed "s|$MODELS_ROOT/||" | while read -r f; do
  size=$(du -sh "$MODELS_ROOT/$f" 2>/dev/null | cut -f1)
  echo "  $size  $f"
done
