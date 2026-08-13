# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.6-base

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

# Relocate ComfyUI's real site-packages onto the shared network volume (once,
# fleet-wide): pip's "already installed" detection is only reliable against
# the actual running environment, not an isolated --target/venv, so instead
# of installing elsewhere we make the real site-packages dir itself shared.
NETWORK_SITE_PACKAGES_DIR="$(resolve_network_path "${NETWORK_CUSTOM_NODE_DEPS_ROOT:-runpod-slim/ComfyUI/site-packages}")"
SITE_PACKAGES_DIR="$(python -c 'import site; print(site.getsitepackages()[0])')"

if [ ! -L "$SITE_PACKAGES_DIR" ]; then
  mkdir -p "$(dirname "$NETWORK_SITE_PACKAGES_DIR")"
  # flock guards the one-time seed copy so concurrent first-boot workers can't
  # corrupt each other; a crashed holder releases it for free.
  (
    flock -x 200
    if [ ! -d "$NETWORK_SITE_PACKAGES_DIR" ]; then
      echo "Seeding shared site-packages: $NETWORK_SITE_PACKAGES_DIR"
      cp -a "$SITE_PACKAGES_DIR" "$NETWORK_SITE_PACKAGES_DIR.partial" &
      CP_PID=$!
      while kill -0 "$CP_PID" 2>/dev/null; do
        sleep 10
        echo "Still copying site-packages... ($(du -sh "$NETWORK_SITE_PACKAGES_DIR.partial" 2>/dev/null | cut -f1) so far)"
      done
      wait "$CP_PID"
      mv "$NETWORK_SITE_PACKAGES_DIR.partial" "$NETWORK_SITE_PACKAGES_DIR"
      echo "Finished seeding shared site-packages"
    fi
  ) 200>"$NETWORK_SITE_PACKAGES_DIR.lock"
  rm -rf "$SITE_PACKAGES_DIR"
  ln -s "$NETWORK_SITE_PACKAGES_DIR" "$SITE_PACKAGES_DIR"
fi

# flock serializes concurrent workers so simultaneous installs into the
# shared site-packages can't corrupt each other; a crashed holder releases it for free.
(
  flock -x 200

  for req in "$COMFY_CUSTOM_NODES_ROOT"/*/requirements.txt; do
    [ -f "$req" ] || continue
    echo "Installing requirements: $req"
    pip install --no-cache-dir -r "$req" || echo "WARNING: failed to install $req"
  done
) 200>"$NETWORK_SITE_PACKAGES_DIR.lock"

echo "Model and custom node symlinks setup complete"
exec "$WORKER_START_SCRIPT"
EOF
RUN chmod +x /opt/setup-models.sh

CMD ["/opt/setup-models.sh"]
