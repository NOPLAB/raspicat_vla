/// セッション内で全モダリティに共通の単調時計。
///
/// アプリ内ではモダリティ間の同期をしない (docs/design/logger_app_spec.md §2)。
/// 代わりに全サンプルへ同一 [MonoClock] の `t_mono_ns` を打ち、壁時計アンカーは
/// [wallAnchorMs] に一度だけ記録する。整列は学習ボックス側の変換で行う。
library;

/// 単調増加のセッション時計。開始時点を 0 とした経過ナノ秒を返す。
class MonoClock {
  MonoClock() : _sw = Stopwatch()..start(), _wallAnchorMs = _nowMs();

  final Stopwatch _sw;
  final int _wallAnchorMs;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// セッション開始からの経過ナノ秒。Stopwatch の分解能はマイクロ秒なので
  /// 実効精度は 1µs だが、契約上のフィールド名は t_mono_ns に統一する。
  int nowNs() => _sw.elapsedMicroseconds * 1000;

  /// セッション開始時刻の壁時計 (Unix epoch ミリ秒)。meta.json のアンカー。
  int get wallAnchorMs => _wallAnchorMs;
}
