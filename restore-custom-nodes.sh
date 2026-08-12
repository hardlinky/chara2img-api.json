#!/bin/bash
set -e

NETWORK_CUSTOM_NODES_ROOT="${NETWORK_CUSTOM_NODES_ROOT:-/workspace/custom_nodes}"

mkdir -p "$NETWORK_CUSTOM_NODES_ROOT"
cd "$NETWORK_CUSTOM_NODES_ROOT"

restore_repo() {
  local repo_url="$1"
  local repo_name="$2"
  local target_path="$NETWORK_CUSTOM_NODES_ROOT/$repo_name"

  if [ -d "$target_path/.git" ] || [ -d "$target_path" ]; then
    echo "Custom node already present: $target_path"
    return
  fi

  echo "Cloning custom node: $repo_url -> $target_path"
  git clone --depth 1 "$repo_url" "$target_path"
}

restore_repo "https://github.com/Smirnov75/ComfyUI-mxToolkit.git" "ComfyUI-mxToolkit"
restore_repo "https://github.com/kijai/ComfyUI-KJNodes.git" "ComfyUI-KJNodes"
restore_repo "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" "ComfyUI_UltimateSDUpscale"

echo "Custom node restore complete: $NETWORK_CUSTOM_NODES_ROOT"
