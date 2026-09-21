# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.6-base-cuda12.8.1

# The base image starts ComfyUI with "--verbose ${COMFY_LOG_LEVEL:-DEBUG}",
# which logs a line per node import and per model-directory scan. Those scans
# hit the network volume, so the spam is both noise and synchronous NFS work.
ENV COMFY_LOG_LEVEL=INFO

# Create model subdirectories (replaced with network-volume links at runtime)
RUN mkdir -p /comfyui/models/checkpoints /comfyui/models/vae /comfyui/models/loras \
    /comfyui/models/upscale_models /comfyui/models/ultralytics/segm /comfyui/models/ultralytics/bbox \
    /comfyui/models/sams

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
# "sams" (plural) is the folder name Impact Pack's SAMLoader registers.
link_model_dir "$NETWORK_MODELS_ROOT/sams" "sams"

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
  mkdir -p "$NETWORK_VENV_DIR"
  # flock guards the seed copy so concurrent first-boot workers can't corrupt
  # each other; a crashed holder releases it for free.
  (
    flock -x 200
    if [ ! -f "$NETWORK_VENV_DIR/.seed-complete" ]; then
      echo "Seeding shared venv (resumable): $NETWORK_VENV_DIR"
      # rsync (not cp): a worker killed mid-copy (e.g. execution timeout) must
      # not lose progress. rsync only renames a file to its final name once
      # fully transferred, so re-running after an interruption correctly
      # skips completed files and resumes the one that was in-flight — cp's
      # mtime-based "-u" skip logic can't tell a half-written file from a
      # finished one and would silently leave it corrupted.
      if ! command -v rsync >/dev/null 2>&1; then
        echo "rsync not found; installing..."
        apt-get update -qq && apt-get install -y -qq rsync
      fi
      # Measured once up front so each progress line can report a total.
      VENV_TOTAL_BYTES=$(du -sb "$LOCAL_VENV_DIR" 2>/dev/null | cut -f1)
      VENV_TOTAL_HUMAN=$(du -sh "$LOCAL_VENV_DIR" 2>/dev/null | cut -f1)
      echo "Venv size to copy: ${VENV_TOTAL_HUMAN:-unknown}"
      rsync -a --partial "$LOCAL_VENV_DIR"/ "$NETWORK_VENV_DIR"/ &
      CP_PID=$!
      while kill -0 "$CP_PID" 2>/dev/null; do
        sleep 10
        COPIED_HUMAN=$(du -sh "$NETWORK_VENV_DIR" 2>/dev/null | cut -f1)
        COPIED_BYTES=$(du -sb "$NETWORK_VENV_DIR" 2>/dev/null | cut -f1)
        if [ -n "$VENV_TOTAL_BYTES" ] && [ "$VENV_TOTAL_BYTES" -gt 0 ] && [ -n "$COPIED_BYTES" ]; then
          echo "Still copying venv... (${COPIED_HUMAN:-0} / $VENV_TOTAL_HUMAN, $((COPIED_BYTES * 100 / VENV_TOTAL_BYTES))%)"
        else
          echo "Still copying venv... (${COPIED_HUMAN:-0} so far)"
        fi
      done
      wait "$CP_PID"
      touch "$NETWORK_VENV_DIR/.seed-complete"
      echo "Finished seeding shared venv"
    fi
  ) 200>"$NETWORK_VENV_DIR.lock"
  rm -rf "$LOCAL_VENV_DIR"
  ln -s "$NETWORK_VENV_DIR" "$LOCAL_VENV_DIR"
fi

# Installing custom node requirements costs ~50s per boot (one pip process per
# node, plus a "pip freeze" that stats every dist-info over NFS) and is a no-op
# once the shared venv holds them. FULL_START runs it; leave it off for normal
# serverless traffic and switch it on for the boot after changing custom nodes.
case "$(printf '%s' "${FULL_START:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) FULL_START_ENABLED=1 ;;
  *) FULL_START_ENABLED=0 ;;
esac

if [ "$FULL_START_ENABLED" -eq 0 ]; then
  echo "FULL_START is off; assuming custom node requirements are already installed"
else
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

    REQUIREMENT_ARGS=()
    for req in "$COMFY_CUSTOM_NODES_ROOT"/*/requirements.txt; do
      [ -f "$req" ] || continue
      echo "Installing requirements: $req"
      REQUIREMENT_ARGS+=(-r "$req")
    done

    if [ "${#REQUIREMENT_ARGS[@]}" -gt 0 ]; then
      # One resolver pass for all nodes: pip startup and resolution dominate
      # the cost, and a per-node loop pays it once per requirements file.
      if ! pip install -q --no-cache-dir -c "$CONSTRAINTS_FILE" "${REQUIREMENT_ARGS[@]}"; then
        # One unsatisfiable file must not block the others.
        echo "WARNING: combined install failed; retrying per custom node"
        for req in "$COMFY_CUSTOM_NODES_ROOT"/*/requirements.txt; do
          [ -f "$req" ] || continue
          pip install -q --no-cache-dir -c "$CONSTRAINTS_FILE" -r "$req" \
            || echo "WARNING: failed to install $req"
        done
      fi
    fi
  ) 200>"$NETWORK_VENV_DIR.lock"
fi

echo "Model and custom node symlinks setup complete"
exec "$WORKER_START_SCRIPT"
EOF
RUN chmod +x /opt/setup-models.sh

CMD ["/opt/setup-models.sh"]
