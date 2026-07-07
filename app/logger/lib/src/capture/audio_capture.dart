/// push-to-talk 音声メモの録音と (best-effort) 文字起こし。
///
/// 言語アノテーションのメモ用途 (docs/design/logger_app_spec.md §1)。ボタン押下中
/// のみ録音し、離すと 1 クリップ = 1 wav として保存する。**wav が一次データ**で、
/// 文字起こしは端末 STT による best-effort (後からオフラインで差し替え可能)。
///
/// マイクは 1 プロセスしか掴めないのが普通なので、録音 (record) を先に開始して
/// wav を確実に確保し、STT は掴めた時だけ動く。掴めなければ transcript は null の
/// まま (収集は止めない)。
library;

import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../session/mono_clock.dart';
import '../session/session_writer.dart';

/// 1 回の push-to-talk の結果。
class AudioClip {
  AudioClip({
    required this.relPath,
    required this.tStartNs,
    required this.tEndNs,
    this.transcript,
  });

  final String relPath;
  final int tStartNs;
  final int tEndNs;
  final String? transcript;
}

/// push-to-talk 録音器。[begin] で録音開始、[end] でクリップを確定する。
class AudioCapture {
  AudioCapture({required this.clock});

  final MonoClock clock;
  final AudioRecorder _rec = AudioRecorder();
  final SpeechToText _stt = SpeechToText();

  String? _absPath;
  String? _relPath;
  int _startNs = 0;
  String _partial = '';
  bool _sttActive = false;

  bool get isRecording => _relPath != null;

  /// 録音を開始する。SessionWriter から採番したパスへ wav を書く。
  Future<void> begin(SessionWriter writer) async {
    if (isRecording) return;
    if (!await _rec.hasPermission()) {
      throw StateError('microphone permission denied');
    }
    final paths = writer.nextAudioPath();
    _absPath = paths.absPath;
    _relPath = paths.relPath;
    _startNs = clock.nowNs();
    _partial = '';

    // 一次データの wav を先に確保する。
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: _absPath!,
    );

    // STT は best-effort。マイクを掴めなければ静かに諦める。
    try {
      if (await _stt.initialize()) {
        _sttActive = true;
        await _stt.listen(
          onResult: (r) => _partial = r.recognizedWords,
          listenOptions: SpeechListenOptions(partialResults: true),
        );
      }
    } catch (_) {
      _sttActive = false;
    }
  }

  /// 録音を止めてクリップを確定する。何も録れていなければ null。
  Future<AudioClip?> end() async {
    if (!isRecording) return null;
    final rel = _relPath!;
    _relPath = null;
    final endNs = clock.nowNs();

    if (_sttActive) {
      try {
        await _stt.stop();
      } catch (_) {}
      _sttActive = false;
    }
    await _rec.stop();

    final transcript = _partial.trim().isEmpty ? null : _partial.trim();
    return AudioClip(
      relPath: rel,
      tStartNs: _startNs,
      tEndNs: endNs,
      transcript: transcript,
    );
  }

  Future<void> dispose() async {
    if (isRecording) {
      await end();
    }
    await _rec.dispose();
  }
}
