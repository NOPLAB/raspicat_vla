/// ゴール指定パネル (text / pose / image)。設定すると [onGoal] を呼ぶ。
library;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../goal.dart';

class GoalPanel extends StatefulWidget {
  const GoalPanel({
    super.key,
    required this.onGoal,
    required this.currentFrame,
  });

  final ValueChanged<Goal> onGoal;

  /// 直近のカメラフレーム (image ゴール用)。未取得なら null。
  final img.Image? Function() currentFrame;

  @override
  State<GoalPanel> createState() => _GoalPanelState();
}

class _GoalPanelState extends State<GoalPanel> {
  GoalMode _mode = GoalMode.text;
  final _textCtrl = TextEditingController(text: 'go straight');
  final _xCtrl = TextEditingController(text: '2.0');
  final _yCtrl = TextEditingController(text: '0.0');
  final _thetaCtrl = TextEditingController(text: '0.0');
  String _imageStatus = '未取得';

  @override
  void dispose() {
    _textCtrl.dispose();
    _xCtrl.dispose();
    _yCtrl.dispose();
    _thetaCtrl.dispose();
    super.dispose();
  }

  void _apply() {
    switch (_mode) {
      case GoalMode.text:
        widget.onGoal(Goal.text(_textCtrl.text.trim()));
      case GoalMode.pose:
        widget.onGoal(Goal.pose(
          double.tryParse(_xCtrl.text) ?? 0,
          double.tryParse(_yCtrl.text) ?? 0,
          double.tryParse(_thetaCtrl.text) ?? 0,
        ));
      case GoalMode.image:
        final frame = widget.currentFrame();
        if (frame == null) {
          setState(() => _imageStatus = 'フレーム未取得');
          return;
        }
        widget.onGoal(Goal.image(img.copyResize(frame, width: 96, height: 96)));
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('ゴール指定', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<GoalMode>(
            segments: const [
              ButtonSegment(value: GoalMode.text, label: Text('テキスト'), icon: Icon(Icons.text_fields)),
              ButtonSegment(value: GoalMode.pose, label: Text('ポーズ'), icon: Icon(Icons.explore)),
              ButtonSegment(value: GoalMode.image, label: Text('画像'), icon: Icon(Icons.image)),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 16),
          _buildInput(),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _apply,
            icon: const Icon(Icons.navigation),
            label: const Text('このゴールで開始'),
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
    switch (_mode) {
      case GoalMode.text:
        return TextField(
          controller: _textCtrl,
          decoration: const InputDecoration(
            labelText: '自然言語の指示 (例: go to the blue trash bin)',
            border: OutlineInputBorder(),
          ),
        );
      case GoalMode.pose:
        return Row(
          children: [
            Expanded(child: _numField(_xCtrl, 'x[m] 前方')),
            const SizedBox(width: 8),
            Expanded(child: _numField(_yCtrl, 'y[m] 左')),
            const SizedBox(width: 8),
            Expanded(child: _numField(_thetaCtrl, 'θ[rad]')),
          ],
        );
      case GoalMode.image:
        return Row(
          children: [
            Expanded(child: Text('現在のカメラフレームをゴール画像にします ($_imageStatus)')),
          ],
        );
    }
  }

  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}
