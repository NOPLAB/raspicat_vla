/// ゴール指定 (text / pose / image)。proto の GoalSpec と対応。
library;

import 'package:image/image.dart' as img;

import 'config.dart';

enum GoalMode { text, pose, image }

extension GoalModeX on GoalMode {
  String get wire => switch (this) {
        GoalMode.text => 'text',
        GoalMode.pose => 'pose',
        GoalMode.image => 'image',
      };

  /// OmniVLA-edge の modality id。
  int get modalityId => switch (this) {
        GoalMode.text => OmniVlaConfig.modalityText,
        GoalMode.pose => OmniVlaConfig.modalityPose,
        GoalMode.image => OmniVlaConfig.modalityImage,
      };
}

/// 1つのナビゲーションゴール。使わないフィールドは null / 空。
class Goal {
  Goal.text(this.text)
      : mode = GoalMode.text,
        poseXyTheta = null,
        image = null;

  /// [x], [y] はロボット相対メートル (x=前方, y=左), [theta] は rad。
  /// v1 ではスマホ UI で直接指定 (docs/mobile_port_spec.md 未決事項C=確定)。
  Goal.pose(double x, double y, double theta)
      : mode = GoalMode.pose,
        text = '',
        poseXyTheta = [x, y, theta],
        image = null;

  Goal.image(this.image)
      : mode = GoalMode.image,
        text = '',
        poseXyTheta = null;

  final GoalMode mode;
  final String text;
  final List<double>? poseXyTheta; // [x, y, theta]
  final img.Image? image;

  /// ゴール識別用の安定キー。切替検知 (Pi 側ウォッチドッグ) とキャッシュに使う。
  String get id => switch (mode) {
        GoalMode.text => 'text:$text',
        GoalMode.pose => 'pose:${poseXyTheta!.map((v) => v.toStringAsFixed(3)).join(",")}',
        GoalMode.image => 'image:${image.hashCode}',
      };

  @override
  String toString() => id;
}
