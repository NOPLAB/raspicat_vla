/// カメラを設定周期で連番 JPEG 保存するキャプチャ。
///
/// app/inference と同じく startImageStream で最新フレームだけ保持し、
/// Timer.periodic (config.cameraPeriod) でその 1 枚を JPEG 化して
/// SessionWriter へ渡す。crop/resize はせず生アスペクトで保存する。
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../config.dart';
import '../session/mono_clock.dart';
import '../session/session_writer.dart';
import 'camera_image_utils.dart';

/// カメラプレビュー＋設定周期での JPEG 保存を担う。
class CameraCapture {
  CameraCapture({required this.config, required this.clock});

  final LoggerConfig config;
  final MonoClock clock;

  CameraController? _controller;
  CameraImage? _latest;
  Timer? _timer;
  SessionWriter? _writer;
  bool _encoding = false; // 前フレームのエンコード中は次ティックをスキップ

  CameraController? get controller => _controller;

  /// カメラを初期化しプレビューを開始する (録画前でも表示できる)。
  Future<void> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('no camera available');
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      back,
      // 中解像度フルフレーム方針。medium は端末により 480p〜720p。
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    await controller.startImageStream((image) => _latest = image);
    _controller = controller;
  }

  /// このセッションへの JPEG 書き出しを開始する。
  void startRecording(SessionWriter writer) {
    _writer = writer;
    _timer = Timer.periodic(config.cameraPeriod, (_) => _tick());
  }

  /// JPEG 書き出しを止める (プレビューは継続)。
  void stopRecording() {
    _timer?.cancel();
    _timer = null;
    _writer = null;
  }

  Future<void> _tick() async {
    final writer = _writer;
    final frame = _latest;
    if (writer == null || frame == null || _encoding) return;
    _encoding = true;
    final tNs = clock.nowNs();
    try {
      final rgb = cameraImageToRgb(frame);
      final jpeg = img.encodeJpg(rgb, quality: config.jpegQuality);
      await writer.addFrame(jpeg, tNs, rgb.width, rgb.height);
    } catch (_) {
      // 1 フレームのエンコード失敗は無視して次へ (収集を止めない)。
    } finally {
      _encoding = false;
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.stopImageStream();
      } catch (_) {}
      await c.dispose();
    }
  }
}
