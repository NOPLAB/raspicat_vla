/// OmniVlaEngine — スマホ上の推論オーケストレーション。
///
/// `omnivla_edge_engine.py` の `OmniVLAEdgeEngine.infer_chunk` をそのまま移植:
///  1. 現在フレームを正規化しリングバッファへ push
///  2. 7 入力 tensor を組み立て (§3.1)
///  3. CLIP text 特徴をプロンプト単位でキャッシュ
///  4. ONNX 本体を実行し action chunk (8,4) を得る
///
/// ONNX 資産が未配置なら [OrtRunner] が null を返すので、動作確認用のダミー
/// 軌道 (ゴールへ緩く向かう前進弧) にフォールバックする。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'action_chunk.dart';
import 'clip_tokenizer.dart';
import 'config.dart';
import 'goal.dart';
import 'inference/ort_runner.dart';
import 'preprocessing.dart';

class OmniVlaEngine {
  OmniVlaEngine({OrtRunner? runner, ClipTokenizer? tokenizer})
      : _runner = runner ?? OrtRunner(),
        _tokenizer = tokenizer ?? ClipTokenizer();

  final OrtRunner _runner;
  final ClipTokenizer _tokenizer;
  final ObsRingBuffer _ring = ObsRingBuffer();
  late final Float32List _black96 = blackChw(OmniVlaConfig.obsSize);

  // CLIP text 特徴のキャッシュ (プロンプト単位)。
  String? _textCacheKey;
  Float32List? _textCacheFeat;

  bool get modelAvailable => _runner.modelAvailable;
  bool get textEncoderReady => _runner.textAvailable && _tokenizer.ready;

  Future<void> init() async {
    await _runner.init();
    await _tokenizer.init();
  }

  /// ゴール切替時など履歴を破棄する。
  void reset() {
    _ring.reset();
    _textCacheKey = null;
    _textCacheFeat = null;
  }

  /// 1 フレーム分の推論。[curRgb] は RGB (できれば FOV 調整済み)。
  ActionChunk inferChunk(img.Image curRgb, Goal goal) {
    // 1. 観測履歴。
    _ring.push(normalizeChw(curRgb, OmniVlaConfig.obsSize));
    final obsImages = _ring.stack(); // (1,18,96,96)
    final curLarge = normalizeChw(curRgb, OmniVlaConfig.largeSize);

    // 2. ゴール tensor。
    final goalPose = goal.mode == GoalMode.pose && goal.poseXyTheta != null
        ? poseGoalVector(goal.poseXyTheta!)
        : Float32List(OmniVlaConfig.actionDim);

    final goalImage = goal.mode == GoalMode.image && goal.image != null
        ? normalizeChw(goal.image!, OmniVlaConfig.obsSize)
        : _black96;

    // map_images = cat(black, black, obs_image_cur) -> (1,9,96,96)
    final area = OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;
    final mapImages = Float32List(9 * area)
      ..setRange(0, 3 * area, _black96)
      ..setRange(3 * area, 6 * area, _black96)
      ..setRange(6 * area, 9 * area, _ring.current);

    // 3. text 特徴 (キャッシュ)。
    final featText = _textFeatures(goal.mode == GoalMode.text ? goal.text : '');

    // 4. 推論 (未配置ならダミー)。
    final out = _runner.runModel(
      obsImages: obsImages,
      goalPose: goalPose,
      mapImages: mapImages,
      goalImage: goalImage,
      modalityId: goal.mode.modalityId,
      featText: featText,
      curLarge: curLarge,
    );
    if (out != null && out.length == OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim) {
      return ActionChunk(out, fromModel: true);
    }
    return _dummyChunk(goal);
  }

  Float32List _textFeatures(String text) {
    if (text == _textCacheKey && _textCacheFeat != null) {
      return _textCacheFeat!;
    }
    Float32List feat;
    final tokens = _tokenizer.tokenize(text.isEmpty ? 'xxxx' : text);
    final encoded = _runner.encodeText(tokens);
    feat = (encoded != null && encoded.length == OmniVlaConfig.clipTextDim)
        ? encoded
        : Float32List(OmniVlaConfig.clipTextDim); // 未配置時はゼロ
    _textCacheKey = text;
    _textCacheFeat = feat;
    return feat;
  }

  /// モデル未配置時の可視化用ダミー: ゴール方向へ緩く前進する弧。
  ActionChunk _dummyChunk(Goal goal) {
    // ゴールから概略の方位を決める。
    double heading = 0.0; // rad, 左が正
    if (goal.mode == GoalMode.pose && goal.poseXyTheta != null) {
      heading = math.atan2(goal.poseXyTheta![1], goal.poseXyTheta![0]);
    } else {
      // text/image はデモ用に軽く蛇行。
      heading = 0.2 * math.sin(DateTime.now().millisecondsSinceEpoch / 1000.0);
    }
    heading = heading.clamp(-0.6, 0.6);

    final raw = Float32List(OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim);
    var x = 0.0, y = 0.0, th = 0.0;
    for (var i = 0; i < OmniVlaConfig.lenTrajPred; i++) {
      th += heading / OmniVlaConfig.lenTrajPred;
      x += math.cos(th); // 前進 1 unit
      y += math.sin(th);
      final o = i * OmniVlaConfig.actionDim;
      raw[o] = x;
      raw[o + 1] = y;
      raw[o + 2] = math.cos(th);
      raw[o + 3] = math.sin(th);
    }
    return ActionChunk(raw, fromModel: false);
  }

  void dispose() => _runner.dispose();
}
