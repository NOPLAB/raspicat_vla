/// AR (ARKit/ARCore) の VIO 姿勢を pose.csv に記録する。
///
/// ネイティブ AR セッションが出す姿勢ストリームを購読し、受信時に共有 MonoClock で
/// スタンプして SessionWriter へ渡す (IMU/GNSS と同じ流儀)。座標規約の正規化はしない
/// — world 位置(m)とクォータニオンを生のまま残し、変換側が position/yaw に落とす。
library;

import 'dart:async';

import '../session/mono_clock.dart';
import '../session/session_writer.dart';
import 'ar_session.dart';

/// 姿勢ストリームを購読し SessionWriter へ書き出す。
class PoseCapture {
  PoseCapture({required this.ar, required this.clock});

  final ArSession ar;
  final MonoClock clock;

  StreamSubscription<ArPoseSample>? _sub;
  SessionWriter? _writer;

  /// このセッションへの姿勢書き出しを開始する。購読開始でネイティブが姿勢を流し始める。
  void start(SessionWriter writer) {
    _writer = writer;
    _sub = ar.poses().listen((p) {
      _writer?.addPose(
        clock.nowNs(),
        p.tx,
        p.ty,
        p.tz,
        p.qx,
        p.qy,
        p.qz,
        p.qw,
        p.trackingState,
      );
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _writer = null;
  }
}
