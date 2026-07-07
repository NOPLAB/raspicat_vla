/// カメラフレーム (CameraImage) を package:image の RGB [img.Image] に変換する。
///
/// Android は YUV420、iOS は BGRA8888 が来る。ロガーは**中解像度フルフレームを
/// 生アスペクトのまま**保存するので crop/resize はしない (変換は学習ボックス側)。
/// 変換ロジックは app/inference/lib/src/camera_image_utils.dart と同一。
library;

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// CameraImage を RGB [img.Image] に変換。未対応フォーマットは例外。
img.Image cameraImageToRgb(CameraImage image) {
  switch (image.format.group) {
    case ImageFormatGroup.yuv420:
      return _yuv420ToRgb(image);
    case ImageFormatGroup.bgra8888:
      return _bgra8888ToRgb(image);
    default:
      throw UnsupportedError('unsupported camera format: ${image.format.group}');
  }
}

img.Image _yuv420ToRgb(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final out = img.Image(width: width, height: height);

  // 3 プレーン (Android: Y/U/V 分離) と 2 プレーン (iOS: NV12, CbCr インター
  // リーブ) の両対応。NV12 では V は U の隣バイトにある。
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final biPlanar = image.planes.length < 3;
  final vPlane = biPlanar ? uPlane : image.planes[2];
  final vByteShift = biPlanar ? 1 : 0;

  final yRowStride = yPlane.bytesPerRow;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? (biPlanar ? 2 : 1);

  final yBytes = yPlane.bytes;
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;

  for (var y = 0; y < height; y++) {
    final yRow = y * yRowStride;
    final uvRow = (y >> 1) * uvRowStride;
    for (var x = 0; x < width; x++) {
      final yValue = yBytes[yRow + x];
      final uvCol = (x >> 1) * uvPixelStride;
      final uValue = uBytes[uvRow + uvCol];
      final vValue = vBytes[uvRow + uvCol + vByteShift];

      // BT.601 full-range 変換。
      final yv = yValue.toDouble();
      final uv = uValue - 128.0;
      final vv = vValue - 128.0;
      var r = (yv + 1.402 * vv).round();
      var g = (yv - 0.344136 * uv - 0.714136 * vv).round();
      var b = (yv + 1.772 * uv).round();
      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);
      out.setPixelRgb(x, y, r, g, b);
    }
  }
  return out;
}

img.Image _bgra8888ToRgb(CameraImage image) {
  final plane = image.planes[0];
  return img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: plane.bytes.buffer,
    rowStride: plane.bytesPerRow,
    order: img.ChannelOrder.bgra,
  );
}
