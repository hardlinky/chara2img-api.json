#!/bin/bash

# Script to manage Chara2IMG models on RunPod Network Volume
# This script helps download, sync, and verify models

set -e

# Configuration
MODELS_DIR="${1:-.}"
NETWORK_MODELS_ROOT="${2:-/workspace/models}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Model definitions
declare -A MODELS=(
  [checkpoints_wai]="https://huggingface.co/Ine007/waiIllustriousSDXL_v160/resolve/main/waiIllustriousSDXL_v160.safetensors"
  [vae_sdxl]="https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors"
  [upscale_4x]="https://huggingface.co/MIUProject/VNCCS/resolve/main/models/upscale_models/4x_APISR_GRL_GAN_generator.pth"
  [lora_houtengeki]="https://huggingface.co/tglink/Houtengeki-Style-IL/resolve/main/Houtengeki_Style.safetensors"
  [yolov8_segm]="https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt"
  [yolov8_bbox]="https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt"
)

# Model to directory mapping
declare -A MODEL_PATHS=(
  [checkpoints_wai]="checkpoints/waiIllustriousSDXL_v160.safetensors"
  [vae_sdxl]="vae/sdxl_vae.safetensors"
  [upscale_4x]="upscale_models/4x_APISR_GRL_GAN_generator.pth"
  [lora_houtengeki]="loras/Houtengeki_Style.safetensors"
  [yolov8_segm]="ultralytics/segm/person_yolov8m-seg.pt"
  [yolov8_bbox]="ultralytics/bbox/face_yolov8m.pt"
)

# Helper to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Download a single model
download_model() {
  local key=$1
  local url="${MODELS[$key]}"
  local target_path="${MODEL_PATHS[$key]}"
  local full_path="${MODELS_DIR}/${target_path}"
  local dir=$(dirname "$full_path")
  
  # Check if file already exists
  if [ -f "$full_path" ]; then
    print_success "Already exists: $target_path"
    return 0
  fi
  
  # Create directory if needed
  mkdir -p "$dir"
  
  print_status "Downloading $key from HuggingFace..."
  print_status "Target: $full_path"
  
  if command_exists wget; then
    wget -O "$full_path" "$url" || {
      print_error "Failed to download $key"
      return 1
    }
  elif command_exists curl; then
    curl -L -o "$full_path" "$url" || {
      print_error "Failed to download $key"
      return 1
    }
  else
    print_error "Neither wget nor curl found. Please install one of them."
    return 1
  fi
  
  print_success "Downloaded $key"
}

# Verify models directory structure
verify_structure() {
  print_status "Verifying directory structure..."
  
  local dirs=(
    "checkpoints"
    "vae"
    "loras"
    "upscale_models"
    "ultralytics/segm"
    "ultralytics/bbox"
  )
  
  for dir in "${dirs[@]}"; do
    local full_path="${MODELS_DIR}/${dir}"
    if [ -d "$full_path" ]; then
      print_success "✓ $dir exists"
      local count=$(find "$full_path" -type f 2>/dev/null | wc -l)
      print_status "  Contains $count file(s)"
    else
      print_warning "✗ $dir missing"
      mkdir -p "$full_path"
      print_status "  Created: $dir"
    fi
  done
}

# List all available models
list_models() {
  print_status "Available models for download:"
  echo ""
  for key in "${!MODELS[@]}"; do
    local path="${MODEL_PATHS[$key]}"
    echo "  $key"
    echo "    Path: $path"
    echo "    URL:  ${MODELS[$key]}"
    echo ""
  done
}

# Calculate total model size
estimate_size() {
  print_status "Estimating total model size..."
  echo ""
  echo "  Model sizes (approximate):"
  echo "    - waiIllustriousSDXL_v160.safetensors:   ~9 GB"
  echo "    - sdxl_vae.safetensors:                   ~170 MB"
  echo "    - 4x_APISR_GRL_GAN_generator.pth:        ~500 MB"
  echo "    - Houtengeki_Style.safetensors:          ~150 MB"
  echo "    - person_yolov8m-seg.pt:                 ~40 MB"
  echo "    - face_yolov8m.pt:                       ~40 MB"
  echo ""
  echo "  Total: ~10.3 GB (minimum recommended: 50-100 GB for flexibility)"
  echo ""
}

# Show usage
show_usage() {
  cat << 'EOF'
Usage: ./manage-models.sh [COMMAND] [OPTIONS]

Commands:
  download [MODEL_KEY] ...  Download specific model(s)
                            Example: ./manage-models.sh download checkpoints_wai vae_sdxl
                            
  download-all              Download all models
  
  verify                    Verify directory structure and list existing models
  
  list                      List all available models with URLs and sizes
  
  size                      Estimate total model storage needed
  
  sync [SOURCE] [DEST]      Sync models from source to destination
                            Example: ./manage-models.sh sync /local/models /network/models

Options:
  --models-dir PATH         Set models directory (default: current directory)
  --network-root PATH       Set network volume root (for documentation)
  --help, -h                Show this help message

Environment Variables:
  MODELS_DIR                Override default models directory
  NETWORK_MODELS_ROOT       Override default network root path

Examples:
  # Download specific models
  ./manage-models.sh download checkpoints_wai vae_sdxl
  
  # Download all models
  ./manage-models.sh download-all
  
  # Verify setup
  ./manage-models.sh verify
  
  # With custom directory
  ./manage-models.sh --models-dir /mnt/chara2img-models verify
  
  # Sync models to network volume
  ./manage-models.sh sync ~/local-models /workspace/models
EOF
}

# Main command dispatcher
main() {
  if [ $# -eq 0 ]; then
    print_error "No command specified"
    echo ""
    show_usage
    exit 1
  fi
  
  local cmd=$1
  shift
  
  case $cmd in
    download)
      if [ $# -eq 0 ]; then
        print_error "Please specify model(s) to download"
        list_models
        exit 1
      fi
      for model in "$@"; do
        if [ -n "${MODELS[$model]:-}" ]; then
          download_model "$model"
        else
          print_error "Unknown model: $model"
        fi
      done
      verify_structure
      ;;
      
    download-all)
      print_status "Downloading all models..."
      for key in "${!MODELS[@]}"; do
        download_model "$key"
      done
      verify_structure
      print_success "All models downloaded successfully!"
      ;;
      
    verify)
      verify_structure
      ;;
      
    list)
      list_models
      ;;
      
    size)
      estimate_size
      ;;
      
    sync)
      if [ $# -lt 2 ]; then
        print_error "sync requires SOURCE and DESTINATION arguments"
        echo "Usage: ./manage-models.sh sync /source/path /dest/path"
        exit 1
      fi
      local src=$1
      local dst=$2
      print_status "Syncing models from $src to $dst..."
      if command_exists rsync; then
        rsync -avz --delete "$src/" "$dst/"
        print_success "Sync complete!"
      else
        print_error "rsync not found. Using cp instead..."
        cp -rv "$src/" "$dst/"
        print_success "Copy complete!"
      fi
      ;;
      
    help|-h|--help)
      show_usage
      ;;
      
    *)
      print_error "Unknown command: $cmd"
      echo ""
      show_usage
      exit 1
      ;;
  esac
}

# Parse global options
while [[ $# -gt 0 ]]; do
  case $1 in
    --models-dir)
      MODELS_DIR=$2
      shift 2
      ;;
    --network-root)
      NETWORK_MODELS_ROOT=$2
      shift 2
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

# Run main function with remaining arguments
main "$@"
