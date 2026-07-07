/// セッション内で全モダリティに共通の単調時計。
///
/// アプリ内ではモダリティ間の同期をしない (docs/design/logger_app_spec.md §2)。
/// 代わりに全サンプルへ同一 [MonoClock] の `t_mono_ns` を打ち、壁時計アンカーは
/// [wallAnchorMs] に一度だけ記録する。整列は学習ボックス側の変換で行う。
library;

/// 単調増加のセッション時計。開始時点を 0 とした経過ナノ秒を返す。
///
/// **1 セッション = 1 度の [reset]**。Recorder が構築時に 1 個だけ生成し、全キャプチャ
/// (カメラ/IMU/GNSS/音声/ラベル) がこの同一インスタンスを共有する。録画開始で
/// [reset] して 0 に戻すことで、全モダリティが同じ session-relative な t_mono_ns を
/// 打つ。インスタンスを差し替えるとカメラだけ古い時計を掴んで時計系がズレるので、
/// 差し替えではなく必ず [reset] を使うこと。
class MonoClock {
  MonoClock() : _sw = Stopwatch()..start(), _wallAnchorMs = _nowMs();

  final Stopwatch _sw;
  int _wallAnchorMs;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// セッション開始からの経過ナノ秒。Stopwatch の分解能はマイクロ秒なので
  /// 実効精度は 1µs だが、契約上のフィールド名は t_mono_ns に統一する。
  int nowNs() => _sw.elapsedMicroseconds * 1000;

  /// セッション開始時刻の壁時計 (Unix epoch ミリ秒)。meta.json のアンカー。
  int get wallAnchorMs => _wallAnchorMs;

  /// 経過を 0 に戻し壁時計アンカーを取り直す。録画開始時に呼ぶ。Stopwatch は
  /// 走ったまま (reset は running 中でも elapsed を 0 にしてカウント継続)。
  void reset() {
    _sw.reset();
    _wallAnchorMs = _nowMs();
  }
}
