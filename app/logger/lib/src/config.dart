/// ロガーの既定設定。UI から一部を上書きできる。
///
/// このアプリは「素直な生ログ収集器」であり、ここにある値は**キャプチャ周期や
/// 保存解像度**といった収集側パラメータのみ。学習側の前処理定数
/// (`app/inference/lib/src/config.dart` の mirror) とは無関係で、揃える必要はない。
/// 詳細は docs/design/logger_app_spec.md を参照。
library;

/// キャプチャ周期・解像度などの収集設定。イミュータブルに扱う。
class LoggerConfig {
  const LoggerConfig({
    this.cameraHz = 4.0,
    this.imuHz = 50.0,
    this.gnssHz = 1.0,
    this.jpegQuality = 85,
    this.embodiment = 'raspicat',
    this.driveFolderId,
  });

  /// カメラ保存周期 [Hz]。startImageStream の最新フレームをこの周期で JPEG 化。
  final double cameraHz;

  /// IMU サンプリング周期 [Hz]。端末が対応する最寄りのレートに丸められる。
  final double imuHz;

  /// GNSS サンプリング周期 [Hz]。多くの端末で 1Hz が上限。
  final double gnssHz;

  /// 連番 JPEG のエンコード品質 (0-100)。
  final int jpegQuality;

  /// 機体ヒント。meta.json に載せ、変換時の正規化統計選択に使う。
  final String embodiment;

  /// アップロード先 Google Drive フォルダ ID (未設定なら My Drive 直下)。
  final String? driveFolderId;

  LoggerConfig copyWith({
    double? cameraHz,
    double? imuHz,
    double? gnssHz,
    int? jpegQuality,
    String? embodiment,
    String? driveFolderId,
  }) {
    return LoggerConfig(
      cameraHz: cameraHz ?? this.cameraHz,
      imuHz: imuHz ?? this.imuHz,
      gnssHz: gnssHz ?? this.gnssHz,
      jpegQuality: jpegQuality ?? this.jpegQuality,
      embodiment: embodiment ?? this.embodiment,
      driveFolderId: driveFolderId ?? this.driveFolderId,
    );
  }

  Duration get cameraPeriod => Duration(microseconds: (1e6 / cameraHz).round());
}
