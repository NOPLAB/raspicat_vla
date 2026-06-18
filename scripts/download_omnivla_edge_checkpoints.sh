#!/usr/bin/env bash
# Download the OmniVLA-edge on-device policy (NHirose/omnivla-edge) into
# ./models/omnivla-edge/. This is the Plan 2B Path 2 checkpoint — the full
# policy that runs on the robot (adapter_kind=omnivla_edge_local):
#   - omnivla-edge.pth   (EfficientNet-b0 encoders + FiLM + transformer decoder)
# CLIP ViT-B/32 is fetched separately by the `clip` package at first load.
#
# Path 1 (cloud OmniVLA-original) uses scripts/download_omnivla_checkpoints.sh.
#
# Uses the host's ~/.cache/huggingface so repeat runs are instant.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/models/omnivla-edge"

mkdir -p "${OUT_DIR}"

python3 - <<PY
import os
from huggingface_hub import snapshot_download

p = snapshot_download(
    repo_id="NHirose/omnivla-edge",
    local_dir="${OUT_DIR}",
    local_dir_use_symlinks=False,
)
print(f"== NHirose/omnivla-edge -> {p}")
for root, _, files in os.walk(p):
    for f in files:
        full = os.path.join(root, f)
        size_mb = os.path.getsize(full) / (1024 * 1024)
        print(f"   {os.path.relpath(full, p)}  ({size_mb:.1f} MB)")
PY
