/// IMU (加速度・ジャイロ・磁気) を設定レートで imu.csv に記録する。
///
/// sensors_plus は融合済みクォータニオンを出さないので、生の 3 センサ値を
/// そのまま残す (フュージョンは学習ボックス側の変換の責務)。加速度イベントを
/// 基準ティックとし、その時点の最新ジャイロ/磁気を同じ行に載せる。
library;

import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../config.dart';
import '../session/mono_clock.dart';
import '../session/session_writer.dart';

/// IMU ストリームを購読し SessionWriter へ書き出す。
class ImuCapture {
  ImuCapture({required this.config, required this.clock});

  final LoggerConfig config;
  final MonoClock clock;

  final List<StreamSubscription<dynamic>> _subs = [];
  SessionWriter? _writer;

  double _gx = 0, _gy = 0, _gz = 0;
  double _mx = 0, _my = 0, _mz = 0;

  Duration get _period => Duration(microseconds: (1e6 / config.imuHz).round());

  void start(SessionWriter writer) {
    _writer = writer;
    final period = _period;
    _subs.add(
      gyroscopeEventStream(samplingPeriod: period).listen((e) {
        _gx = e.x;
        _gy = e.y;
        _gz = e.z;
      }),
    );
    _subs.add(
      magnetometerEventStream(samplingPeriod: period).listen((e) {
        _mx = e.x;
        _my = e.y;
        _mz = e.z;
      }),
    );
    // 加速度を基準ティックにする (最新のジャイロ/磁気を同じ行へ)。
    _subs.add(
      accelerometerEventStream(samplingPeriod: period).listen((e) {
        _writer?.addImu(
          clock.nowNs(),
          e.x,
          e.y,
          e.z,
          _gx,
          _gy,
          _gz,
          _mx,
          _my,
          _mz,
        );
      }),
    );
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _writer = null;
  }
}
