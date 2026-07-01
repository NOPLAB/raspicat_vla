/// ONNX Runtime ラッパー: OmniVLA-edge 本体 + CLIP text encoder。
///
/// Phase 1 で `omnivla-edge.pth` と CLIP を ONNX 化し、以下へ配置する想定:
///   assets/models/omnivla_edge.onnx   (7入力 -> action(1,8,4))
///   assets/models/clip_text.onnx      (tokens(1,77) -> feat(1,512))
///
/// モデル未配置でも UI が動くよう、ロード失敗時は [modelAvailable] / [textAvailable]
/// を false にし、呼び出し側 (OmniVlaEngine) がダミー軌道へフォールバックする。
/// 入力名は export 時に確定させ、[_modelInputNames] を合わせること。
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../config.dart';

/// export 後に実際の入力名へ更新する (docs/mobile_port_spec.md §3.1 の 7 入力)。
const _modelInputNames = (
  obsImages: 'obs_images',
  goalPose: 'goal_pose',
  mapImages: 'map_images',
  goalImage: 'goal_image',
  modalityId: 'modality_id',
  featText: 'feat_text',
  curLarge: 'cur_large',
);
const _modelAsset = 'assets/models/omnivla_edge.onnx';
const _textAsset = 'assets/models/clip_text.onnx';
const _textInputName = 'tokens';
const _eotInputName = 'eot_index';

/// 推論に使う intra-op スレッド数。既定 (0) だと ORT が全コアを掴んで CPU 100%
/// になり Flutter の描画/GC が枯渇して画面が固まる。意図的に絞って残りを UI に回す。
const _intraOpThreads = 2;

class OrtRunner {
  OrtSession? _model;
  OrtSession? _text;

  bool get modelAvailable => _model != null;
  bool get textAvailable => _text != null;

  Future<void> init() async {
    OrtEnv.instance.init();
    _model = await _tryLoad(_modelAsset);
    _text = await _tryLoad(_textAsset);
  }

  /// ロード失敗の理由 (UI/診断用)。
  String lastError = '';

  Future<OrtSession?> _tryLoad(String asset) async {
    try {
      final raw = await rootBundle.load(asset);
      final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      final options = OrtSessionOptions()
        ..setIntraOpNumThreads(_intraOpThreads)
        ..setInterOpNumThreads(1);
      return OrtSession.fromBuffer(bytes, options);
    } catch (e) {
      // 未配置 or ロード失敗。フォールバックへ。
      lastError = '$asset: $e';
      // ignore: avoid_print
      print('[OrtRunner] load failed $lastError');
      return null;
    }
  }

  /// CLIP トークン列 (長さ 77) を 512 次元特徴へ。[eotIndex] は EOT トークンの
  /// 位置 (argmax の代替。モバイル ORT に ArgMax が無いため外から渡す)。未ロード時 null。
  Future<Float32List?> encodeText(Int32List tokens, int eotIndex) async {
    final session = _text;
    if (session == null) return null;
    // ONNX の tokens 入力は int64。Int32List のままだと型不一致で失敗する。
    final input = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(tokens),
      [1, OmniVlaConfig.clipContextLength],
    );
    final eot = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList([eotIndex]),
      [1],
    );
    final runOptions = OrtRunOptions();
    try {
      // runAsync: 別 isolate で実行し UI スレッドを塞がない。
      final future =
          session.runAsync(runOptions, {_textInputName: input, _eotInputName: eot});
      final outputs = future == null ? null : await future;
      if (outputs == null) return null;
      final flat = _flattenToFloat32(outputs.first?.value);
      for (final o in outputs) {
        o?.release();
      }
      return flat;
    } finally {
      input.release();
      eot.release();
      runOptions.release();
    }
  }

  /// 7 入力を渡し action chunk (flatten 済み 8*4) を返す。未ロード時は null。
  Future<Float32List?> runModel({
    required Float32List obsImages, // (1,18,96,96)
    required Float32List goalPose, // (1,4)
    required Float32List mapImages, // (1,9,96,96)
    required Float32List goalImage, // (1,3,96,96)
    required int modalityId,
    required Float32List featText, // (1,512)
    required Float32List curLarge, // (1,3,224,224)
  }) async {
    final session = _model;
    if (session == null) return null;

    const s = OmniVlaConfig.obsSize;
    const l = OmniVlaConfig.largeSize;
    final inputs = <String, OrtValue>{
      _modelInputNames.obsImages: OrtValueTensor.createTensorWithDataList(
          obsImages, [1, 3 * OmniVlaConfig.historyLen, s, s]),
      _modelInputNames.goalPose:
          OrtValueTensor.createTensorWithDataList(goalPose, [1, 4]),
      _modelInputNames.mapImages:
          OrtValueTensor.createTensorWithDataList(mapImages, [1, 9, s, s]),
      _modelInputNames.goalImage:
          OrtValueTensor.createTensorWithDataList(goalImage, [1, 3, s, s]),
      _modelInputNames.modalityId: OrtValueTensor.createTensorWithDataList(
          Int64List.fromList([modalityId]), [1]),
      _modelInputNames.featText: OrtValueTensor.createTensorWithDataList(
          featText, [1, OmniVlaConfig.clipTextDim]),
      _modelInputNames.curLarge:
          OrtValueTensor.createTensorWithDataList(curLarge, [1, 3, l, l]),
    };
    final runOptions = OrtRunOptions();
    try {
      // runAsync: 別 isolate で実行し UI スレッドを塞がない。
      final future = session.runAsync(runOptions, inputs);
      final outputs = future == null ? null : await future;
      if (outputs == null) return null;
      // 出力先頭が action_pred (1, 8, 4) 想定。
      final flat = _flattenToFloat32(outputs.first?.value);
      for (final o in outputs) {
        o?.release();
      }
      return flat;
    } finally {
      for (final v in inputs.values) {
        v.release();
      }
      runOptions.release();
    }
  }

  void dispose() {
    _model?.release();
    _text?.release();
    OrtEnv.instance.release();
  }

  /// ORT の value.value はネストした List。再帰的に flatten して Float32List に。
  static Float32List _flattenToFloat32(Object? value) {
    final acc = <double>[];
    void walk(Object? v) {
      if (v is num) {
        acc.add(v.toDouble());
      } else if (v is Iterable) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(value);
    return Float32List.fromList(acc);
  }
}
