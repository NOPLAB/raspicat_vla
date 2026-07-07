/// セッションディレクトリの生成と各ログファイルへの追記を担う。
///
/// レイアウトは docs/design/logger_app_spec.md §3 の通り:
///   `<base>/logger_sessions/<session_id>/`
///     meta.json / camera/frames/*.jpg / camera/frames.csv /
///     pose/pose.csv / imu/imu.csv / gnss/gnss.csv / audio/*.wav / labels.jsonl
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import 'mono_clock.dart';

/// 1 録画セッション分の書き出し器。[create] で開き、[finish] で閉じる。
class SessionWriter {
  SessionWriter._(this.dir, this.config, this.clock);

  final Directory dir;
  final LoggerConfig config;
  final MonoClock clock;

  late final IOSink _framesCsv;
  late final IOSink _poseCsv;
  late final IOSink _imuCsv;
  late final IOSink _gnssCsv;
  late final IOSink _labels;

  int _frameNo = 0;
  int _poseNo = 0;
  int _audioNo = 0;
  bool _closed = false;

  String get sessionId => p.basename(dir.path);

  /// `<baseDir>/logger_sessions/<session_id>/` を作り、各 CSV/JSONL を開く。
  static Future<SessionWriter> create({
    required Directory baseDir,
    required LoggerConfig config,
    required MonoClock clock,
  }) async {
    // session_id は開始壁時計から採番 (アプリ内では乱数を避け、UI 操作で確定する
    // タイムスタンプを使う。衝突回避に ms 精度)。
    final ts = DateTime.fromMillisecondsSinceEpoch(clock.wallAnchorMs);
    final id =
        'sess_'
        '${ts.year.toString().padLeft(4, '0')}'
        '${ts.month.toString().padLeft(2, '0')}'
        '${ts.day.toString().padLeft(2, '0')}_'
        '${ts.hour.toString().padLeft(2, '0')}'
        '${ts.minute.toString().padLeft(2, '0')}'
        '${ts.second.toString().padLeft(2, '0')}';

    final dir = Directory(p.join(baseDir.path, 'logger_sessions', id));
    await Directory(
      p.join(dir.path, 'camera', 'frames'),
    ).create(recursive: true);
    await Directory(p.join(dir.path, 'pose')).create(recursive: true);
    await Directory(p.join(dir.path, 'imu')).create(recursive: true);
    await Directory(p.join(dir.path, 'gnss')).create(recursive: true);
    await Directory(p.join(dir.path, 'audio')).create(recursive: true);

    final w = SessionWriter._(dir, config, clock);
    w._framesCsv = File(p.join(dir.path, 'camera', 'frames.csv')).openWrite(
      mode: FileMode.write,
    )..writeln('frame_no,t_mono_ns,width,height');
    // 姿勢は world 座標系の位置(m) + クォータニオン。座標規約は meta.platform で
    // 判別 (ARKit=.gravity / ARCore 既定、共に Y-up 右手系だが軸の向きが異なる)。
    w._poseCsv = File(p.join(dir.path, 'pose', 'pose.csv')).openWrite(
      mode: FileMode.write,
    )..writeln('t_mono_ns,tx,ty,tz,qx,qy,qz,qw,tracking_state');
    w._imuCsv = File(p.join(dir.path, 'imu', 'imu.csv')).openWrite(
      mode: FileMode.write,
    )..writeln('t_mono_ns,ax,ay,az,gx,gy,gz,mx,my,mz');
    w._gnssCsv = File(p.join(dir.path, 'gnss', 'gnss.csv')).openWrite(
      mode: FileMode.write,
    )..writeln('t_mono_ns,lat,lon,alt,acc,speed,bearing');
    w._labels = File(
      p.join(dir.path, 'labels.jsonl'),
    ).openWrite(mode: FileMode.write);
    return w;
  }

  /// JPEG フレームを保存し frames.csv に 1 行追記。フレーム番号を返す。
  Future<int> addFrame(List<int> jpeg, int tNs, int width, int height) async {
    final no = _frameNo++;
    final name = '${no.toString().padLeft(8, '0')}.jpg';
    await File(p.join(dir.path, 'camera', 'frames', name)).writeAsBytes(jpeg);
    _framesCsv.writeln('$no,$tNs,$width,$height');
    return no;
  }

  /// VIO 姿勢 1 サンプルを pose.csv に追記する。位置(tx,ty,tz)はメートル、
  /// (qx,qy,qz,qw)は world→camera の回転クォータニオン。座標規約の正規化は
  /// せず生のまま残す (変換側が meta.platform を見て position/yaw へ落とす)。
  void addPose(
    int tNs,
    double tx,
    double ty,
    double tz,
    double qx,
    double qy,
    double qz,
    double qw,
    String trackingState,
  ) {
    _poseNo++;
    _poseCsv.writeln('$tNs,$tx,$ty,$tz,$qx,$qy,$qz,$qw,$trackingState');
  }

  /// 生の加速度 (a)・ジャイロ (g)・磁気 (m)。フュージョンは変換側で行う。
  void addImu(
    int tNs,
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz,
    double mx,
    double my,
    double mz,
  ) {
    _imuCsv.writeln('$tNs,$ax,$ay,$az,$gx,$gy,$gz,$mx,$my,$mz');
  }

  void addGnss(
    int tNs,
    double lat,
    double lon,
    double alt,
    double acc,
    double speed,
    double bearing,
  ) {
    _gnssCsv.writeln('$tNs,$lat,$lon,$alt,$acc,$speed,$bearing');
  }

  /// 次の音声クリップの保存先絶対パスを採番して返す (録音器が書き込む)。
  /// 返す相対パスは labels.jsonl の `audio_clip` に使う。
  ({String absPath, String relPath}) nextAudioPath() {
    final no = _audioNo++;
    final rel = p.join('audio', '${(no).toString().padLeft(4, '0')}.wav');
    return (absPath: p.join(dir.path, rel), relPath: rel);
  }

  /// 意味づけラベルを labels.jsonl に 1 行追記。
  void addLabel({
    required int tStartNs,
    required int tEndNs,
    required String prompt,
    String? audioClip,
    String? transcript,
    String source = 'app',
  }) {
    _labels.writeln(
      jsonEncode({
        't_start_mono_ns': tStartNs,
        't_end_mono_ns': tEndNs,
        'prompt': prompt,
        'audio_clip': ?audioClip,
        'transcript': ?transcript,
        'source': source,
      }),
    );
  }

  /// meta.json を書き、全シンクを flush/close する。冪等。
  Future<void> finish({
    required String platform,
    required String appVersion,
  }) async {
    if (_closed) return;
    _closed = true;
    final meta = {
      'session_id': sessionId,
      'app_version': appVersion,
      'platform': platform,
      'embodiment': config.embodiment,
      'clock': 'mono_ns_from_session_start',
      'wall_anchor_ms': clock.wallAnchorMs,
      'session_start_mono_ns': 0,
      'session_end_mono_ns': clock.nowNs(),
      'config': {
        'camera_hz': config.cameraHz,
        'pose_hz': config.poseHz,
        'imu_hz': config.imuHz,
        'gnss_hz': config.gnssHz,
        'jpeg_quality': config.jpegQuality,
      },
      'frame_count': _frameNo,
      'pose_count': _poseNo,
      'audio_count': _audioNo,
    };
    await File(
      p.join(dir.path, 'meta.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
    await _framesCsv.flush();
    await _framesCsv.close();
    await _poseCsv.flush();
    await _poseCsv.close();
    await _imuCsv.flush();
    await _imuCsv.close();
    await _gnssCsv.flush();
    await _gnssCsv.close();
    await _labels.flush();
    await _labels.close();
  }
}
