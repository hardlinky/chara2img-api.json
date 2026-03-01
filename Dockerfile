# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.5.1-base

# install custom nodes into comfyui (first node with --mode remote to fetch updated cache)
RUN comfy node install --exit-on-fail rgthree-comfy@1.0.2512112053 --mode remote
RUN comfy node install --exit-on-fail comfyui-fbcnn@1.0.1
RUN comfy node install --exit-on-fail ComfyUI_ADV_CLIP_emb
RUN comfy node install --exit-on-fail comfy-image-saver
RUN comfy node install --exit-on-fail comfyui-image-saver@1.21.0
RUN comfy node install --exit-on-fail was-node-suite-comfyui@1.0.2
RUN comfy node install --exit-on-fail comfyui-promptbuilder@2.0.1
# Could not resolve unknown_registry/mxSlider2D - no aux_id provided, skipping (add a git repo aux_id to clone)
RUN comfy node install --exit-on-fail comfyui-easy-use@1.3.6
RUN comfy node install --exit-on-fail comfyui-impact-pack@8.28.2

# download models into comfyui
RUN comfy model download --url https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors --relative-path models/vae --filename sdxl_vae.safetensors
RUN comfy model download --url https://huggingface.co/martineux/waiIllustriousSDXL_v160/resolve/main/waiIllustriousSDXL_v160.safetensors --relative-path models/checkpoints --filename waiIllustriousSDXL_v160.safetensors
RUN comfy model download --url https://huggingface.co/MIUProject/VNCCS/resolve/main/4x_APISR_GRL_GAN_generator.pth --relative-path models/upscale_models --filename 4x_APISR_GRL_GAN_generator.pth
RUN comfy model download --url https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt --relative-path models/ultralytics/segm --filename person_yolov8m-seg.pt
RUN comfy model download --url https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt --relative-path models/ultralytics/bbox --filename face_yolov8m.pt

# copy all input data (like images or videos) into comfyui (uncomment and adjust if needed)
# COPY input/ /comfyui/input/
