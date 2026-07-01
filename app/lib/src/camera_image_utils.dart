/// カメラフレーム (CameraImage) を package:image の RGB [img.Image] に変換する。
///
/// Android は YUV420、iOS は BGRA8888 が来る。OmniVLA-edge は raspicat カメラの
/// 画角で学習しているため (docs/mobile_port_spec.md §5-1 ドメインギャップ)、
/// [centerCropToAspect] で学習時アスペクトに寄せてから正規化する想定。
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
      throw UnsupportedError(
        'unsupported camera format: ${image.format.group}',
      );
  }
}

img.Image _yuv420ToRgb(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final out = img.Image(width: width, height: height);

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final yRowStride = yPlane.bytesPerRow;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

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
      final vValue = vBytes[uvRow + uvCol];

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
  final bgra = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: plane.bytes.buffer,
    rowStride: plane.bytesPerRow,
    order: img.ChannelOrder.bgra,
  );
  return bgra;
}

/// 学習時アスペクト比 (デフォルト 1:1) に中央クロップする。
///
/// スマホカメラの広い画角を raspicat カメラに寄せるための最小対策。実際の
/// クロップ率は実機で要調整 (§5-1, Phase 5)。
img.Image centerCropToAspect(img.Image src, {double aspect = 1.0}) {
  final targetW = src.height * aspect;
  int cropW, cropH;
  if (targetW <= src.width) {
    cropW = targetW.round();
    cropH = src.height;
  } else {
    cropW = src.width;
    cropH = (src.width / aspect).round();
  }
  final x0 = ((src.width - cropW) / 2).round();
  final y0 = ((src.height - cropH) / 2).round();
  return img.copyCrop(src, x: x0, y: y0, width: cropW, height: cropH);
}
