import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
  } catch (_) {
    // カメラ無し (エミュレータ等) でも UI は起動する。
  }
  runApp(RaspicatVlaApp(cameras: cameras));
}

class RaspicatVlaApp extends StatelessWidget {
  const RaspicatVlaApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raspicat OmniVLA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DA9FC),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomePage(cameras: cameras),
    );
  }
}
