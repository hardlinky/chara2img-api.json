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

# Create model subdirectories
RUN mkdir -p /comfyui/models/checkpoints /comfyui/models/vae /comfyui/models/loras \
    /comfyui/models/upscale_models /comfyui/models/ultralytics/segm /comfyui/models/ultralytics/bbox

# Bake fixed workflow dependencies into the image. Checkpoints and LoRAs stay
# on the network volume so they can be managed without rebuilding the image.
RUN comfy model download --url https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors --relative-path models/vae --filename sdxl_vae.safetensors
RUN comfy model download --url https://huggingface.co/MIUProject/VNCCS/resolve/main/models/upscale_models/4x_APISR_GRL_GAN_generator.pth --relative-path models/upscale_models --filename 4x_APISR_GRL_GAN_generator.pth
RUN comfy model download --url https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt --relative-path models/ultralytics/segm --filename person_yolov8m-seg.pt
RUN comfy model download --url https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt --relative-path models/ultralytics/bbox --filename face_yolov8m.pt

# Create entrypoint script to handle network volume symlink setup
RUN cat > /opt/setup-models.sh << 'EOF'
#!/bin/bash
set -e

# Expected network volume mount path (configured in RunPod)
NETWORK_MODELS_ROOT="${NETWORK_MODELS_ROOT:-/workspace/models}"

echo "Setting up model symlinks from network volume: $NETWORK_MODELS_ROOT"

# Function to create symlink safely
create_symlink_if_needed() {
  local target=$1
  local link_name=$2
  
  if [ -d "$target" ]; then
    if [ -e "$link_name" ] && [ ! -L "$link_name" ]; then
      echo "Warning: $link_name exists but is not a symlink. Skipping."
      return
    fi
    if [ ! -e "$link_name" ]; then
      echo "Creating symlink: $link_name -> $target"
      ln -s "$target" "$link_name"
    else
      echo "Symlink already exists: $link_name"
    fi
  else
    echo "Network volume path not found: $target (will be populated later)"
    mkdir -p "$target"
  fi
}

# Create symlinks for user-managed model types
cd /comfyui/models

# Remove checkpoint and LoRA directories and replace them with network links
rm -rf checkpoints loras
create_symlink_if_needed "$NETWORK_MODELS_ROOT/checkpoints" "checkpoints"
create_symlink_if_needed "$NETWORK_MODELS_ROOT/loras" "loras"

echo "Model symlinks setup complete"
EOF
RUN chmod +x /opt/setup-models.sh
