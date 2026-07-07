/// 全モダリティのキャプチャとセッション書き出しを束ねるオーケストレータ。
///
/// カメラのプレビューは常時、録画 (JPEG/IMU/GNSS 書き出し) は start/stop で制御。
/// 音声は push-to-talk で任意区間だけ。意味づけラベルは録画中いつでも追加できる。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'capture/audio_capture.dart';
import 'capture/camera_capture.dart';
import 'capture/gnss_capture.dart';
import 'capture/imu_capture.dart';
import 'config.dart';
import 'session/mono_clock.dart';
import 'session/session_writer.dart';

/// 録画状態を保持しキャプチャ群を駆動する。UI から ChangeNotifier として観測。
class Recorder extends ChangeNotifier {
  Recorder({
    required this.baseDir,
    required this.appVersion,
    LoggerConfig? config,
  }) : config = config ?? const LoggerConfig();

  final Directory baseDir;
  final String appVersion;
  LoggerConfig config;

  late final CameraCapture camera = CameraCapture(
    config: config,
    clock: _clock,
  );
  ImuCapture? _imu;
  GnssCapture? _gnss;
  AudioCapture? _audio;

  // 全キャプチャ (カメラ含む) が共有する唯一の時計。差し替えず reset で 0 に戻す
  // — 差し替えると late final の camera が旧インスタンスを掴んで時計系がズレる。
  final MonoClock _clock = MonoClock();
  SessionWriter? _writer;

  bool get isRecording => _writer != null;
  bool get isTalking => _audio?.isRecording ?? false;
  String? get sessionId => _writer?.sessionId;

  /// カメラプレビューを初期化する (起動時に 1 度)。
  Future<void> initCamera() => camera.initialize();

  void updateConfig(LoggerConfig c) {
    config = c;
    notifyListeners();
  }

  /// 新しいセッションを開始し、カメラ/IMU/GNSS の書き出しを始める。
  Future<void> start() async {
    if (isRecording) return;
    // 共有時計を 0 に戻す (差し替えない)。以降 camera/imu/gnss/audio/label が
    // 同一 session-relative な t_mono_ns を打つ。
    _clock.reset();
    final writer = await SessionWriter.create(
      baseDir: baseDir,
      config: config,
      clock: _clock,
    );
    _writer = writer;

    camera.startRecording(writer);
    _imu = ImuCapture(config: config, clock: _clock)..start(writer);
    _gnss = GnssCapture(config: config, clock: _clock)..start(writer);
    _audio = AudioCapture(clock: _clock);
    notifyListeners();
  }

  /// セッションを停止し meta.json を書き出す。停止したセッションのパスを返す。
  Future<String?> stop() async {
    final writer = _writer;
    if (writer == null) return null;
    _writer = null;

    camera.stopRecording();
    await _imu?.stop();
    await _gnss?.stop();
    await _audio?.dispose();
    _imu = null;
    _gnss = null;
    _audio = null;

    await writer.finish(
      platform: Platform.operatingSystem,
      appVersion: appVersion,
    );
    notifyListeners();
    return writer.dir.path;
  }

  /// push-to-talk 開始 (録画中のみ)。
  Future<void> beginTalk() async {
    final writer = _writer;
    if (writer == null) return;
    await _audio?.begin(writer);
    notifyListeners();
  }

  /// push-to-talk 終了。録れた区間を prompt とともに意味づけラベルにする。
  /// prompt が空でも wav/transcript は残す (オフライン後付け前提)。
  Future<void> endTalk({String prompt = ''}) async {
    final writer = _writer;
    final clip = await _audio?.end();
    notifyListeners();
    if (writer == null || clip == null) return;
    writer.addLabel(
      tStartNs: clip.tStartNs,
      tEndNs: clip.tEndNs,
      prompt: prompt,
      audioClip: clip.relPath,
      transcript: clip.transcript,
      source: 'app',
    );
  }

  /// テキストのみの意味づけラベルを現在時刻区間に追加する。
  void addTextLabel(String prompt, {int? spanNs}) {
    final writer = _writer;
    if (writer == null || prompt.trim().isEmpty) return;
    final now = _clock.nowNs();
    writer.addLabel(
      tStartNs: spanNs == null ? now : now - spanNs,
      tEndNs: now,
      prompt: prompt.trim(),
      source: 'app',
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await camera.dispose();
    super.dispose();
  }
}
