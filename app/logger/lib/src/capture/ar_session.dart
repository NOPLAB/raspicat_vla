/// ネイティブ AR (iOS=ARKit / Android=ARCore) セッションへの薄いブリッジ。
///
/// AR は背面カメラを占有するため、このアプリでは **カメラフレームも VIO 姿勢も**
/// AR セッションから取り出す (`camera` プラグインは使わない)。ネイティブ側は
/// セッション開始後、各 EventChannel に **リスナが付いている間だけ** 間引いた
/// フレーム/姿勢を流す (onListen/onCancel で計算を絞る)。プレビューは PlatformView
/// (iOS=ARSCNView / Android=GLSurfaceView) がネイティブで常時描画する。
///
/// 時刻はここでは打たない。受信側 (CameraCapture / PoseCapture) が共有 MonoClock で
/// スタンプする — IMU/GNSS と同じ流儀 (docs/design/logger_app_spec.md §2)。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const String _prefix = 'com.raspicat.vla_logger/ar';

/// AR セッションの制御・ストリーム・プレビューを束ねる。Recorder が 1 つ持つ。
class ArSession {
  static const MethodChannel _control = MethodChannel('$_prefix/ar_control');
  static const EventChannel _poseCh = EventChannel('$_prefix/ar_pose');
  static const EventChannel _frameCh = EventChannel('$_prefix/ar_frame');

  bool _started = false;
  bool get isStarted => _started;

  /// 端末が AR (ARKit/ARCore) に対応しているか。非対応なら録画不可。
  Future<bool> isSupported() async {
    final ok = await _control.invokeMethod<bool>('isSupported');
    return ok ?? false;
  }

  /// AR セッションを開始する (プレビューが動き出す)。冪等。
  ///
  /// [jpegQuality] はネイティブでのフレーム JPEG エンコード品質。ネイティブは
  /// フレームを [cameraHz]、姿勢を [poseHz] に間引いて各 EventChannel へ流す。
  Future<void> start({
    required double cameraHz,
    required double poseHz,
    required int jpegQuality,
  }) async {
    if (_started) return;
    await _control.invokeMethod<void>('start', {
      'cameraHz': cameraHz,
      'poseHz': poseHz,
      'jpegQuality': jpegQuality,
    });
    _started = true;
  }

  /// AR セッションを停止・破棄する。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _control.invokeMethod<void>('stop');
  }

  /// フレーム列 (JPEG + 解像度)。リスナを張っている間だけネイティブが JPEG 化する。
  Stream<ArFrameSample> frames() =>
      _frameCh.receiveBroadcastStream().map(ArFrameSample._fromEvent);

  /// 姿勢列 (world 位置 + クォータニオン + tracking 状態)。
  Stream<ArPoseSample> poses() =>
      _poseCh.receiveBroadcastStream().map(ArPoseSample._fromEvent);

  /// ネイティブ AR プレビュー (PlatformView)。カメラ映像はネイティブが描画する。
  ///
  /// Android は GLSurfaceView (SurfaceView 系) を確実に描画するため Hybrid Composition
  /// を明示 (既定の Virtual Display では GL/カメラプレビューが出ない)。
  Widget buildPreview() {
    const viewType = '$_prefix/ar_preview';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return const UiKitView(viewType: viewType);
      case TargetPlatform.android:
        return PlatformViewLink(
          viewType: viewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          ),
          onCreatePlatformView: (params) =>
              PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: viewType,
                layoutDirection: TextDirection.ltr,
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              )
                ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                ..create(),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// AR フレーム 1 枚。JPEG は端末側でエンコード済み。
class ArFrameSample {
  const ArFrameSample({
    required this.jpeg,
    required this.width,
    required this.height,
  });

  final Uint8List jpeg;
  final int width;
  final int height;

  factory ArFrameSample._fromEvent(dynamic e) {
    final m = e as Map;
    return ArFrameSample(
      jpeg: m['jpeg'] as Uint8List,
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
    );
  }
}

/// VIO 姿勢 1 サンプル。位置はメートル、回転はクォータニオン (world 座標系)。
/// 座標規約 (ARKit/ARCore の軸差) の正規化はせず生のまま扱う。
class ArPoseSample {
  const ArPoseSample({
    required this.tx,
    required this.ty,
    required this.tz,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.trackingState,
  });

  final double tx, ty, tz;
  final double qx, qy, qz, qw;
  final String trackingState;

  factory ArPoseSample._fromEvent(dynamic e) {
    final m = e as Map;
    double d(String k) => (m[k] as num).toDouble();
    return ArPoseSample(
      tx: d('tx'),
      ty: d('ty'),
      tz: d('tz'),
      qx: d('qx'),
      qy: d('qy'),
      qz: d('qz'),
      qw: d('qw'),
      trackingState: (m['tracking_state'] as String?) ?? 'unknown',
    );
  }
}
