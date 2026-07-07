/// AR セッションが出すカメラフレームを連番 JPEG で保存するキャプチャ。
///
/// AR (ARKit/ARCore) が背面カメラを占有するため、フレームは `camera` プラグインでは
/// なく AR から取り出す。JPEG エンコードと config.cameraHz への間引きはネイティブ側で
/// 行い、ここでは受信したフレームを受信時刻 (共有 MonoClock) でスタンプして書き出す。
/// crop/resize はせず生アスペクトで保存する (縮小はネイティブが中解像度化する範囲のみ)。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config.dart';
import '../session/mono_clock.dart';
import '../session/session_writer.dart';
import 'ar_session.dart';

/// AR プレビュー＋フレームの連番 JPEG 保存を担う。
class CameraCapture {
  CameraCapture({required this.ar, required this.config, required this.clock});

  final ArSession ar;
  final LoggerConfig config;
  final MonoClock clock;

  StreamSubscription<ArFrameSample>? _sub;
  SessionWriter? _writer;
  bool _ready = false;

  /// AR セッションが起動しプレビュー可能か。
  bool get isReady => _ready;

  /// AR セッションを初期化しプレビューを開始する (録画前でも表示できる)。
  /// 端末が AR 非対応なら [StateError] を投げる (このアプリは AR 必須)。
  Future<void> initialize() async {
    if (!await ar.isSupported()) {
      throw StateError('この端末は AR (ARKit/ARCore) に対応していません');
    }
    await ar.start(
      cameraHz: config.cameraHz,
      poseHz: config.poseHz,
      jpegQuality: config.jpegQuality,
    );
    _ready = true;
  }

  /// このセッションへの JPEG 書き出しを開始する。購読開始でネイティブが JPEG 化を始める。
  void startRecording(SessionWriter writer) {
    _writer = writer;
    _sub = ar.frames().listen((f) async {
      final w = _writer;
      if (w == null) return;
      final tNs = clock.nowNs();
      try {
        await w.addFrame(f.jpeg, tNs, f.width, f.height);
      } catch (_) {
        // 1 フレームの書き出し失敗は無視して次へ (収集を止めない)。
      }
    });
  }

  /// JPEG 書き出しを止める (プレビューは継続)。購読解除でネイティブが JPEG 化を止める。
  Future<void> stopRecording() async {
    await _sub?.cancel();
    _sub = null;
    _writer = null;
  }

  /// ネイティブ AR プレビュー Widget。
  Widget buildPreview() => ar.buildPreview();

  Future<void> dispose() async {
    await stopRecording();
    await ar.stop();
    _ready = false;
  }
}
