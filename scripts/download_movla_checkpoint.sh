#!/usr/bin/env bash
# Fetch a movla Stage A checkpoint into ./models/movla/<run>/.
#
# movla checkpoints are not published (in-house model, external/movla); they
# live on the training box as <movla repo>/runs/<run>/{checkpoint.pt,
# normalizer.json} and are pulled over rsync/ssh. The training box may still be
# writing the run — rsync just grabs the latest atomic save (train.py writes
# checkpoint.pt.tmp then renames).
#
# Usage:
#   scripts/download_movla_checkpoint.sh [RUN]        # default: stage_a_v2
# Env overrides:
#   MOVLA_TRAIN_HOST  ssh host of the training box (default: nop@pve1ubuntu)
#   MOVLA_TRAIN_REPO  movla repo path on that box   (default: /home/nop/dev/mywork/movla)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${1:-stage_a_v2}"
HOST="${MOVLA_TRAIN_HOST:-nop@pve1ubuntu}"
SRC="${MOVLA_TRAIN_REPO:-/home/nop/dev/mywork/movla}/runs/${RUN}"
OUT_DIR="${REPO_ROOT}/models/movla/${RUN}"

mkdir -p "${OUT_DIR}"
rsync -av --progress \
    "${HOST}:${SRC}/checkpoint.pt" \
    "${HOST}:${SRC}/normalizer.json" \
    "${OUT_DIR}/"

echo "== movla ${RUN} -> ${OUT_DIR}"
ls -lh "${OUT_DIR}"
