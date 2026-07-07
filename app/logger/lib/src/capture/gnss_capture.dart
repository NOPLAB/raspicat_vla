/// GNSS を設定レートで gnss.csv に記録する。
///
/// getPositionStream を購読し、config.gnssHz の周期に間引いて書き出す
/// (プラットフォーム差を避けるため時間ベースの throttle をアプリ側で行う)。
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config.dart';
import '../session/mono_clock.dart';
import '../session/session_writer.dart';

/// 位置ストリームを購読し SessionWriter へ書き出す。
class GnssCapture {
  GnssCapture({required this.config, required this.clock});

  final LoggerConfig config;
  final MonoClock clock;

  StreamSubscription<Position>? _sub;
  SessionWriter? _writer;
  int _lastWriteNs = -1 << 62;

  int get _periodNs => (1e9 / config.gnssHz).round();

  void start(SessionWriter writer) {
    _writer = writer;
    const settings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      final tNs = clock.nowNs();
      if (tNs - _lastWriteNs < _periodNs) return;
      _lastWriteNs = tNs;
      _writer?.addGnss(
        tNs,
        pos.latitude,
        pos.longitude,
        pos.altitude,
        pos.accuracy,
        pos.speed,
        pos.heading,
      );
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _writer = null;
    _lastWriteNs = -1 << 62;
  }
}
