/// モデル出力の action chunk (len_traj_pred, 4) を保持する。
library;

import 'dart:typed_data';

import 'config.dart';

/// (numTokens, embedDim) の waypoint 群。raw の x,y は waypoint-spacing 単位。
class ActionChunk {
  ActionChunk(this.raw, {this.fromModel = true})
      : assert(raw.length ==
            OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim);

  /// flatten 済み (8*4)。行 = (x, y, cos, sin), 単位は spacing。
  final Float32List raw;

  /// true=ONNX 実推論, false=ダミー(モデル未配置)。
  final bool fromModel;

  int get numTokens => OmniVlaConfig.lenTrajPred;
  int get embedDim => OmniVlaConfig.actionDim;

  /// i 番目の waypoint をメートル系 (x_m, y_m, cos, sin) で返す。
  List<double> rowMetres(int i) {
    final o = i * OmniVlaConfig.actionDim;
    return [
      raw[o] * OmniVlaConfig.metricWaypointSpacing,
      raw[o + 1] * OmniVlaConfig.metricWaypointSpacing,
      raw[o + 2],
      raw[o + 3],
    ];
  }

  /// 全 waypoint の (x_m, y_m)。x=前方, y=左 (ロボット座標)。
  List<(double, double)> get xyMetres => [
        for (var i = 0; i < numTokens; i++)
          (
            raw[i * OmniVlaConfig.actionDim] *
                OmniVlaConfig.metricWaypointSpacing,
            raw[i * OmniVlaConfig.actionDim + 1] *
                OmniVlaConfig.metricWaypointSpacing,
          )
      ];
}
