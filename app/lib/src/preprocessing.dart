/// 前処理: リサイズ / ImageNet 正規化 / リングバッファ / ゴール tensor。
///
/// `omnivla_edge_engine.py` の以下と 1:1 対応 (docs/mobile_port_spec.md §3.2):
///  - `_normalize_chw`  -> [normalizeChw]
///  - `_black_chw`      -> [blackChw]
///  - `_pose_goal_vector` -> [poseGoalVector]
///  - `_stack_frames` / リングバッファ -> [ObsRingBuffer]
///
/// 出力はすべて **CHW・float32・flatten 済み** の [Float32List]。ONNX の入力
/// tensor にそのまま渡せる。数値は PyTorch 参照と突き合わせる (Phase 2 ゴールデン)。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'config.dart';

/// RGB [src] を size×size にリサイズし ImageNet 正規化した CHW float32 を返す。
///
/// 縮小には average 補間 (cv2.INTER_AREA 相当) を使う。長さ 3*size*size。
Float32List normalizeChw(img.Image src, int size) {
  final resized = (src.width == size && src.height == size)
      ? src
      : img.copyResize(
          src,
          width: size,
          height: size,
          interpolation: img.Interpolation.average,
        );

  final area = size * size;
  final out = Float32List(3 * area);
  const mean = OmniVlaConfig.imagenetMean;
  const std = OmniVlaConfig.imagenetStd;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final p = resized.getPixel(x, y);
      final base = y * size + x;
      out[base] = (p.r / 255.0 - mean[0]) / std[0]; // R plane
      out[area + base] = (p.g / 255.0 - mean[1]) / std[1]; // G plane
      out[2 * area + base] = (p.b / 255.0 - mean[2]) / std[2]; // B plane
    }
  }
  return out;
}

/// ImageNet 正規化された全黒 (3, size, size)。衛星マップ/ゴール画像のゼロ埋め。
Float32List blackChw(int size) {
  final area = size * size;
  final out = Float32List(3 * area);
  const mean = OmniVlaConfig.imagenetMean;
  const std = OmniVlaConfig.imagenetStd;
  for (var c = 0; c < 3; c++) {
    final v = (0.0 - mean[c]) / std[c];
    for (var i = 0; i < area; i++) {
      out[c * area + i] = v;
    }
  }
  return out;
}

/// pose ゴール (ロボット相対 [x, y, theta]) から (4,) の goal_pose ベクトルを作る。
///
/// `_pose_goal_vector` と一致: `(rel_y/spacing, -rel_x/spacing, cos, sin)`,
/// 半径を goalDistThresholdM でクランプ。x=前方, y=左。
Float32List poseGoalVector(List<double> xyTheta) {
  var relX = xyTheta[0];
  var relY = xyTheta[1];
  final theta = xyTheta[2];
  final radius = math.sqrt(relX * relX + relY * relY);
  if (radius > OmniVlaConfig.goalDistThresholdM) {
    final scale = OmniVlaConfig.goalDistThresholdM / radius;
    relX *= scale;
    relY *= scale;
  }
  const spacing = OmniVlaConfig.metricWaypointSpacing;
  return Float32List.fromList([
    relY / spacing,
    -relX / spacing,
    math.cos(theta),
    math.sin(theta),
  ]);
}

/// 観測履歴のリングバッファ。各フレームは正規化済み CHW (3, obsSize, obsSize)。
///
/// `omnivla_edge_engine.py` の `_obs_ring` / `_stack_frames` を再現。古い順・
/// 現在最後。不足時は最古フレームで前詰め (cold-start)。
class ObsRingBuffer {
  final List<Float32List> _frames = [];
  final int _capacity = OmniVlaConfig.historyLen;
  int get _frameLen => 3 * OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;

  bool get isEmpty => _frames.isEmpty;

  void reset() => _frames.clear();

  /// 正規化済み現在フレーム (長さ 3*96*96) を push。
  void push(Float32List frameChw) {
    assert(frameChw.length == _frameLen);
    _frames.add(frameChw);
    if (_frames.length > _capacity) {
      _frames.removeAt(0);
    }
  }

  /// 直近フレーム (現在) の CHW。map_images 構築に使う。
  Float32List get current {
    if (_frames.isEmpty) {
      throw StateError('no observation frames buffered yet');
    }
    return _frames.last;
  }

  /// (1, 3*historyLen, 96, 96) を flatten した Float32List。古い順・前詰め。
  Float32List stack() {
    if (_frames.isEmpty) {
      throw StateError('no observation frames buffered yet');
    }
    final need = _capacity;
    final area = OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;
    final out = Float32List(3 * need * area);

    // 前詰め: 不足分は最古フレームを複製。
    final padded = <Float32List>[];
    final deficit = need - _frames.length;
    for (var i = 0; i < deficit; i++) {
      padded.add(_frames.first);
    }
    padded.addAll(_frames);
    // 末尾 need 個 (padded は既に <= need+... だが安全に末尾を取る)。
    final start = padded.length - need;
    var offset = 0;
    for (var i = start; i < padded.length; i++) {
      out.setRange(offset, offset + 3 * area, padded[i]);
      offset += 3 * area;
    }
    return out;
  }
}
