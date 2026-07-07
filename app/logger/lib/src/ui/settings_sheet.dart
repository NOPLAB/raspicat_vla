/// キャプチャ設定の編集シート (録画中は開けない)。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../recorder.dart';

Future<void> showSettingsSheet(BuildContext context, Recorder recorder) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SettingsSheet(recorder: recorder),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.recorder});

  final Recorder recorder;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late LoggerConfig _c = widget.recorder.config;
  late final TextEditingController _embodiment =
      TextEditingController(text: _c.embodiment);
  late final TextEditingController _folder =
      TextEditingController(text: _c.driveFolderId ?? '');

  @override
  void dispose() {
    _embodiment.dispose();
    _folder.dispose();
    super.dispose();
  }

  Widget _rateRow(String label, double value, List<double> choices,
      ValueChanged<double> onPick) {
    return Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: choices
                .map((v) => ChoiceChip(
                      label: Text('$v'),
                      selected: value == v,
                      onSelected: (_) => onPick(v),
                    ))
                .toList(),
          ),
        ),
      ],
    );
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('キャプチャ設定',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
          _rateRow('カメラ', _c.cameraHz, const [1, 2, 4, 8],
              (v) => setState(() => _c = _c.copyWith(cameraHz: v))),
          _rateRow('IMU', _c.imuHz, const [10, 25, 50, 100],
              (v) => setState(() => _c = _c.copyWith(imuHz: v))),
          _rateRow('GNSS', _c.gnssHz, const [0.5, 1, 2],
              (v) => setState(() => _c = _c.copyWith(gnssHz: v))),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 64, child: Text('JPEG')),
              Expanded(
                child: Slider(
                  min: 50,
                  max: 100,
                  divisions: 10,
                  label: '${_c.jpegQuality}',
                  value: _c.jpegQuality.toDouble(),
                  onChanged: (v) =>
                      setState(() => _c = _c.copyWith(jpegQuality: v.round())),
                ),
              ),
            ],
          ),
          TextField(
            controller: _embodiment,
            decoration: const InputDecoration(
              labelText: 'embodiment (機体)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _folder,
            decoration: const InputDecoration(
              labelText: 'Drive フォルダ ID (任意)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                widget.recorder.updateConfig(_c.copyWith(
                  embodiment: _embodiment.text.trim().isEmpty
                      ? 'raspicat'
                      : _embodiment.text.trim(),
                  driveFolderId:
                      _folder.text.trim().isEmpty ? null : _folder.text.trim(),
                ));
                Navigator.of(context).pop();
              },
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
