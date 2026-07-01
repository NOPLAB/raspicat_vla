# ONNX モデル配置場所 (Phase 1)

ここに OmniVLA-edge と CLIP text encoder の ONNX を置く。未配置でもアプリは
起動し、`OmniVlaEngine` はダミー軌道にフォールバックする (推論バッジが「ダミー」表示)。

必要ファイル:

- `omnivla_edge.onnx` — `models/omnivla-edge/omnivla-edge.pth` を ONNX 化。
  入力7本 (docs/mobile_port_spec.md §3.1)、出力 `action_pred (1,8,4)`。
  export 時に `OmniVLA_edge.forward` の `tensor.get_device()` 依存を除去すること。
- `clip_text.onnx` — CLIP ViT-B/32 の text encoder。入力 `tokens (1,77)` int、
  出力 `feat (1,512)`。

export 後、`lib/src/inference/ort_runner.dart` の `_modelInputNames` を実際の
入力名に合わせる。
