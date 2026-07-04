#!/usr/bin/env bash
# app/assets の ONNX モデルと CLIP 語彙を web/public へコピーする (すべて git 管理外)。
# モデル未配置でも web アプリはダミー軌道で動くため、欠けは警告に留める。
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$WEB_DIR/.." && pwd)"

mkdir -p "$WEB_DIR/public/models" "$WEB_DIR/public/clip"

copy() {
  local src="$1" dst="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
    echo "sync: $(basename "$src") -> ${dst#"$WEB_DIR/"}"
  else
    echo "WARN: $src がありません (ダミー軌道フォールバックで動作します)"
  fi
}

copy "$REPO_ROOT/app/assets/models/omnivla_edge.onnx" "$WEB_DIR/public/models/"
copy "$REPO_ROOT/app/assets/models/clip_text.onnx" "$WEB_DIR/public/models/"
copy "$REPO_ROOT/app/assets/clip/bpe_simple_vocab_16e6.txt.gz" "$WEB_DIR/public/clip/"
