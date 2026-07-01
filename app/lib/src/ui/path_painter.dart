/// 予測 waypoint をカメラプレビュー上にトップダウン投影で描く。
library;

import 'package:flutter/material.dart';

/// ロボット座標 (x=前方[m], y=左[m]) の waypoint 列を、画面下端中央を原点に
/// 上方向=前進で描画する簡易オーバーレイ。
class PathPainter extends CustomPainter {
  PathPainter({
    required this.waypoints,
    required this.fromModel,
    this.metresToPixels = 60.0,
  });

  /// (x_m, y_m) 前方・左。
  final List<(double, double)> waypoints;
  final bool fromModel;
  final double metresToPixels;

  @override
  void paint(Canvas canvas, Size size) {
    if (waypoints.isEmpty) return;

    final originX = size.width / 2;
    final originY = size.height - 24;

    Offset project((double, double) p) {
      // x(前方)->上(-y), y(左)->左(-x)
      return Offset(
        originX - p.$2 * metresToPixels,
        originY - p.$1 * metresToPixels,
      );
    }

    final color = fromModel ? const Color(0xFF3DFC9A) : const Color(0xFFFFC24B);
    final line = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()..moveTo(originX, originY);
    for (final wp in waypoints) {
      final o = project(wp);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, line);

    final dot = Paint()..color = color;
    for (final wp in waypoints) {
      canvas.drawCircle(project(wp), 5, dot);
    }
    // ロボット原点。
    canvas.drawCircle(Offset(originX, originY), 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant PathPainter old) =>
      old.waypoints != waypoints || old.fromModel != fromModel;
}
