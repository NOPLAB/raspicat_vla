/// VLA チューニング用ロガー (app/logger, パッケージ `vla_logger`)。
///
/// カメラ / IMU / GNSS / 音声を設定周期でキャプチャして生ログ保存し、後段の変換で
/// LeLaN/GNM/LeRobotDataset へ意味づけしてファインチューニングに使う。
/// 設計は docs/design/logger_app_spec.md。
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/recorder.dart';
import 'src/ui/home_page.dart';

const String _appVersion = '0.1.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Boot());
}

/// 権限要求とカメラ初期化を待ってから HomePage を出すブート画面。
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  late final Future<Recorder> _future = _init();

  Future<Recorder> _init() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.locationWhenInUse,
      Permission.speech,
    ].request();

    final baseDir = await getApplicationDocumentsDirectory();
    final recorder = Recorder(baseDir: baseDir, appVersion: _appVersion);
    await recorder.initCamera();
    return recorder;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VLA Logger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          secondary: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
        ),
      ),
      home: FutureBuilder<Recorder>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
              body: Center(child: Text('初期化エラー: ${snap.error}')),
            );
          }
          if (!snap.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return HomePage(recorder: snap.data!);
        },
      ),
    );
  }
}
