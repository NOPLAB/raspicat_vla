/// メイン画面: カメラプレビュー + 推論ループ + パス可視化 + Pi 送信。
///
/// 観測は obs_publish_rate (~2Hz) で処理する。CameraImage 変換と推論を毎フレーム
/// 走らせない (負荷) ため、最新フレームだけを保持しタイマで tick する。
/// TODO(Phase 5): 変換/推論を Isolate に逃がして UI ジャンクを消す。
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../action_chunk.dart';
import '../camera_image_utils.dart';
import '../goal.dart';
import '../grpc/edge_action_client.dart';
import '../omnivla_engine.dart';
import 'goal_panel.dart';
import 'path_painter.dart';

/// 観測処理レート (Hz)。omnivla_edge_engine の obs_publish_rate に対応。
const _obsRateHz = 2.0;

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  CameraController? _controller;
  final OmniVlaEngine _engine = OmniVlaEngine();
  late final CoalescingSender _sender =
      CoalescingSender(LoggingEdgeClient(), minInterval: const Duration(milliseconds: 100));

  Goal? _goal;
  CameraImage? _latestCameraImage;
  img.Image? _currentFrame; // image ゴール用
  ActionChunk? _chunk;
  Timer? _loop;
  bool _busy = false;
  int _frameId = 0;
  int _lastLatencyMs = 0;
  String _error = '';
  String _engineStatus = '初期化中';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _engine.init();
    setState(() {
      _engineStatus = _engine.modelAvailable
          ? 'ONNX (text=${_engine.textEncoderReady ? "有" : "無"})'
          : 'ダミー (ONNX未配置)';
    });

    if (widget.cameras.isEmpty) {
      setState(() => _error = 'カメラが見つかりません');
      return;
    }
    final granted = await Permission.camera.request();
    if (!granted.isGranted) {
      setState(() => _error = 'カメラ権限がありません');
      return;
    }

    final back = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
      await controller.startImageStream((image) => _latestCameraImage = image);
    } catch (e) {
      setState(() => _error = 'カメラ初期化失敗: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _controller = controller);

    _loop = Timer.periodic(
      Duration(milliseconds: (1000 / _obsRateHz).round()),
      (_) => _tick(),
    );
  }

  Future<void> _tick() async {
    if (_busy) return;
    final goal = _goal;
    final camImage = _latestCameraImage;
    if (goal == null || camImage == null) return;
    _busy = true;
    final sw = Stopwatch()..start();
    try {
      final rgb = centerCropToAspect(cameraImageToRgb(camImage));
      _currentFrame = rgb;
      final chunk = _engine.inferChunk(rgb, goal);
      _frameId++;
      _sender.submit(chunk, frameId: _frameId, goalId: goal.id);
      sw.stop();
      if (mounted) {
        setState(() {
          _chunk = chunk;
          _lastLatencyMs = sw.elapsedMilliseconds;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '推論エラー: $e');
    } finally {
      _busy = false;
    }
  }

  void _setGoal(Goal goal) {
    _engine.reset();
    setState(() {
      _goal = goal;
      _chunk = null;
    });
  }

  void _openGoalPanel() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => GoalPanel(onGoal: _setGoal, currentFrame: () => _currentFrame),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loop?.cancel();
    _controller?.dispose();
    _engine.dispose();
    _sender.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Raspicat OmniVLA (edge)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'Raspicat OmniVLA',
              children: const [
                Text('スマホがカメラ取得+OmniVLA-edge推論、Raspberry Piがモーター制御。'),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openGoalPanel,
        icon: const Icon(Icons.flag),
        label: Text(_goal == null ? 'ゴール設定' : 'ゴール変更'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48),
              const SizedBox(height: 12),
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('推論エンジン: $_engineStatus',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                if (_chunk != null)
                  CustomPaint(
                    painter: PathPainter(
                      waypoints: _chunk!.xyMetres,
                      fromModel: _chunk!.fromModel,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(top: 8, left: 8, right: 8, child: _statusBar()),
      ],
    );
  }

  Widget _statusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(fontSize: 12, color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('エンジン: $_engineStatus   推論: ${_lastLatencyMs}ms'),
            Text('ゴール: ${_goal?.id ?? "未設定"}'),
            Text('送信: ${_sender.status}'),
          ],
        ),
      ),
    );
  }
}
