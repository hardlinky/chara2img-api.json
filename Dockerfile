# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.6-base-cuda12.8.1

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

# Relocate the entire launch venv onto the shared network volume (once,
# fleet-wide): symlinking just site-packages breaks packages that install
# data-file scripts via a "../../../bin" relative path, because ".." through a
# symlink resolves against the target's real (differently-nested) location.
# Moving bin/, lib/, pyvenv.cfg etc. together keeps their relative nesting
# intact, so only the /opt/venv absolute prefix changes (transparently, via
# the symlink) while every internal relative-path assumption stays valid.
NETWORK_VENV_DIR="$(resolve_network_path "${NETWORK_CUSTOM_NODE_DEPS_ROOT:-runpod-slim/ComfyUI/venv}")"
# Hardcoded, not discovered via sys.prefix: bin/python is a symlink to
# /usr/bin/python, and CPython's venv detection can fail to resolve pyvenv.cfg
# through it, silently falling back to the SYSTEM prefix — which previously
# caused "rm -rf" to target /usr and start deleting the NVIDIA driver.
LOCAL_VENV_DIR="${LOCAL_VENV_DIR:-/opt/venv}"

# Safety net: refuse to touch anything that isn't a plausible, dedicated venv
# path, however LOCAL_VENV_DIR ends up being set.
case "$LOCAL_VENV_DIR" in
  ""|/|/usr|/usr/*|/bin|/bin/*|/lib|/lib/*|/etc|/etc/*)
    echo "Refusing to relocate suspicious venv path: '$LOCAL_VENV_DIR'" >&2
    exit 1
    ;;
esac

if [ ! -L "$LOCAL_VENV_DIR" ]; then
  mkdir -p "$(dirname "$NETWORK_VENV_DIR")"
  # flock guards the one-time seed copy so concurrent first-boot workers can't
  # corrupt each other; a crashed holder releases it for free.
  (
    flock -x 200
    if [ ! -d "$NETWORK_VENV_DIR" ]; then
      echo "Seeding shared venv: $NETWORK_VENV_DIR"
      cp -a "$LOCAL_VENV_DIR" "$NETWORK_VENV_DIR.partial" &
      CP_PID=$!
      while kill -0 "$CP_PID" 2>/dev/null; do
        sleep 10
        echo "Still copying venv... ($(du -sh "$NETWORK_VENV_DIR.partial" 2>/dev/null | cut -f1) so far)"
      done
      wait "$CP_PID"
      mv "$NETWORK_VENV_DIR.partial" "$NETWORK_VENV_DIR"
      echo "Finished seeding shared venv"
    fi
  ) 200>"$NETWORK_VENV_DIR.lock"
  rm -rf "$LOCAL_VENV_DIR"
  ln -s "$NETWORK_VENV_DIR" "$LOCAL_VENV_DIR"
fi

# flock serializes concurrent workers so simultaneous installs into the
# shared venv can't corrupt each other; a crashed holder releases it for free.
(
  flock -x 200

  # Custom node requirements often declare a bare, unpinned "torch" — without
  # a constraint, pip can silently swap the base image's carefully pinned
  # cu128 torch build for a newer default (cu13) wheel that needs a driver
  # version this fleet doesn't have. Freezing current versions as constraints
  # lets pip add genuinely new packages without ever touching what's already there.
  CONSTRAINTS_FILE="/tmp/pinned-venv-packages.txt"
  pip freeze --local > "$CONSTRAINTS_FILE"

  for req in "$COMFY_CUSTOM_NODES_ROOT"/*/requirements.txt; do
    [ -f "$req" ] || continue
    echo "Installing requirements: $req"
    pip install --no-cache-dir -c "$CONSTRAINTS_FILE" -r "$req" || echo "WARNING: failed to install $req"
  done
) 200>"$NETWORK_VENV_DIR.lock"

echo "Model and custom node symlinks setup complete"
exec "$WORKER_START_SCRIPT"
EOF
RUN chmod +x /opt/setup-models.sh

CMD ["/opt/setup-models.sh"]
