# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.5.1-base

# install custom nodes into comfyui (first node with --mode remote to fetch updated cache)
RUN comfy node install --exit-on-fail ComfyUI_ADV_CLIP_emb --mode remote
RUN comfy node install --exit-on-fail comfyui-easy-use@1.3.6
RUN comfy node install --exit-on-fail comfyui-fbcnn@1.0.1
RUN comfy node install --exit-on-fail comfyui-image-saver@1.21.0
RUN comfy node install --exit-on-fail comfyui-impact-pack@8.28.2
RUN comfy node install --exit-on-fail comfyui-impact-subpack@1.3.5
RUN comfy node install --exit-on-fail comfyui-promptbuilder@2.0.1
RUN comfy node install --exit-on-fail rgthree-comfy@1.0.2512112053
RUN comfy node install --exit-on-fail was-node-suite-comfyui@1.0.2

#RUN comfy node install --exit-on-fail ComfyUI-mxToolkit
RUN cd /comfyui/custom_nodes && git clone https://github.com/Smirnov75/ComfyUI-mxToolkit.git && cd /
#RUN comfy node install --exit-on-fail ComfyUI-KJNodes@1.3.1
RUN cd /comfyui/custom_nodes && git clone https://github.com/kijai/ComfyUI-KJNodes && cd /
#RUN comfy node install --exit-on-fail ComfyUI_UltimateSDUpscale
RUN cd /comfyui/custom_nodes && git clone https://github.com/ssitu/ComfyUI_UltimateSDUpscale && cd /

# Create model subdirectories (replaced with network-volume links at runtime)
RUN mkdir -p /comfyui/models/checkpoints /comfyui/models/vae /comfyui/models/loras \
    /comfyui/models/upscale_models /comfyui/models/ultralytics/segm /comfyui/models/ultralytics/bbox

COPY restore-models.sh /opt/restore-models.sh
RUN chmod +x /opt/restore-models.sh

# Restore only missing network models, link them into ComfyUI, then start the worker
RUN cat > /opt/setup-models.sh << 'EOF'
#!/bin/bash
set -e

NETWORK_MODELS_ROOT="${NETWORK_MODELS_ROOT:-/workspace/models}"
COMFY_MODELS_ROOT="${COMFY_MODELS_ROOT:-/comfyui/models}"
RESTORE_MODELS_SCRIPT="${RESTORE_MODELS_SCRIPT:-/opt/restore-models.sh}"
WORKER_START_SCRIPT="${WORKER_START_SCRIPT:-/start.sh}"

echo "Restoring missing models on network volume: $NETWORK_MODELS_ROOT"
MODELS_ROOT="$NETWORK_MODELS_ROOT" "$RESTORE_MODELS_SCRIPT"

link_model_dir() {
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

echo "Model symlinks setup complete"
exec "$WORKER_START_SCRIPT"
EOF
RUN chmod +x /opt/setup-models.sh

CMD ["/opt/setup-models.sh"]
