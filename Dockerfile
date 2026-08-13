# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.5.1-base

# Create model subdirectories (replaced with network-volume links at runtime)
RUN mkdir -p /comfyui/models/checkpoints /comfyui/models/vae /comfyui/models/loras \
    /comfyui/models/upscale_models /comfyui/models/ultralytics/segm /comfyui/models/ultralytics/bbox

# Link shared network model and custom-node directories into ComfyUI, then start the worker
RUN cat > /opt/setup-models.sh << 'EOF'
#!/bin/bash
set -e

# Serverless workers always mount the network volume at /runpod-volume.
NETWORK_MOUNT_DIR="${NETWORK_MOUNT_DIR:-/runpod-volume}"
resolve_network_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$NETWORK_MOUNT_DIR/$1" ;;
  esac
}

NETWORK_MODELS_ROOT="$(resolve_network_path "${NETWORK_MODELS_ROOT:-runpod-slim/ComfyUI/models}")"
NETWORK_CUSTOM_NODES_ROOT="$(resolve_network_path "${NETWORK_CUSTOM_NODES_ROOT:-runpod-slim/ComfyUI/custom_nodes}")"
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
