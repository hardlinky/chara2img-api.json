# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.5.1-base

# Create model subdirectories (replaced with network-volume links at runtime)
RUN mkdir -p /comfyui/models/checkpoints /comfyui/models/vae /comfyui/models/loras \
    /comfyui/models/upscale_models /comfyui/models/ultralytics/segm /comfyui/models/ultralytics/bbox

# Link shared network model and custom-node directories into ComfyUI, then start the worker
RUN cat > /opt/setup-models.sh << 'EOF'
#!/bin/bash
set -e

# Network volume mounts at different paths depending on resource type:
# /workspace on Pods, /runpod-volume on serverless workers. Auto-detect so
# the same subpath env vars work everywhere; NETWORK_VOLUME_ROOT can force it.
detect_volume_root() {
  if [ -n "${NETWORK_VOLUME_ROOT:-}" ]; then
    echo "$NETWORK_VOLUME_ROOT"
  elif [ -d /runpod-volume ] && [ -n "$(ls -A /runpod-volume 2>/dev/null)" ]; then
    echo /runpod-volume
  elif [ -d /workspace ] && [ -n "$(ls -A /workspace 2>/dev/null)" ]; then
    echo /workspace
  else
    echo /runpod-volume
  fi
}

VOLUME_ROOT="$(detect_volume_root)"
echo "Detected network volume root: $VOLUME_ROOT"

MODELS_SUBPATH="${NETWORK_MODELS_SUBPATH:-runpod-slim/ComfyUI/models}"
CUSTOM_NODES_SUBPATH="${NETWORK_CUSTOM_NODES_SUBPATH:-runpod-slim/ComfyUI/custom_nodes}"

# NETWORK_MODELS_ROOT / NETWORK_CUSTOM_NODES_ROOT remain as absolute-path overrides.
NETWORK_MODELS_ROOT="${NETWORK_MODELS_ROOT:-$VOLUME_ROOT/$MODELS_SUBPATH}"
NETWORK_CUSTOM_NODES_ROOT="${NETWORK_CUSTOM_NODES_ROOT:-$VOLUME_ROOT/$CUSTOM_NODES_SUBPATH}"
COMFY_MODELS_ROOT="${COMFY_MODELS_ROOT:-/comfyui/models}"
COMFY_CUSTOM_NODES_ROOT="${COMFY_CUSTOM_NODES_ROOT:-/comfyui/custom_nodes}"
WORKER_START_SCRIPT="${WORKER_START_SCRIPT:-/start.sh}"

link_model_dir() {
  local target=$1
  local link_name=$2

  mkdir -p "$target"
  rm -rf "$link_name"
  ln -s "$target" "$link_name"
  echo "Linked $link_name -> $target"
}

link_custom_node_dir() {
  local target=$1
  local link_name=$2

  mkdir -p "$target"
  rm -rf "$link_name"
  ln -s "$target" "$link_name"
  echo "Linked $link_name -> $target"
}

mkdir -p "$COMFY_MODELS_ROOT"
cd "$COMFY_MODELS_ROOT"
link_model_dir "$NETWORK_MODELS_ROOT/checkpoints" "checkpoints"
link_model_dir "$NETWORK_MODELS_ROOT/vae" "vae"
link_model_dir "$NETWORK_MODELS_ROOT/loras" "loras"
link_model_dir "$NETWORK_MODELS_ROOT/upscale_models" "upscale_models"
link_model_dir "$NETWORK_MODELS_ROOT/ultralytics" "ultralytics"

mkdir -p "$COMFY_CUSTOM_NODES_ROOT"
cd /comfyui
link_custom_node_dir "$NETWORK_CUSTOM_NODES_ROOT" "custom_nodes"

# Custom node source lives on the shared network volume, but each container
# has its own Python env, so dependencies must be installed here every boot.
for req in "$COMFY_CUSTOM_NODES_ROOT"/*/requirements.txt; do
  [ -f "$req" ] || continue
  echo "Installing requirements: $req"
  pip install --no-cache-dir -r "$req" || echo "WARNING: failed to install $req"
done

echo "Model and custom node symlinks setup complete"
exec "$WORKER_START_SCRIPT"
EOF
RUN chmod +x /opt/setup-models.sh

CMD ["/opt/setup-models.sh"]
