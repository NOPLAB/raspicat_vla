/// 録画のメイン画面。プレビュー・録画トグル・push-to-talk・prompt 入力。
///
/// UI は白黒モノトーンの銘板調 (アクセント色を使わない)。
library;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../recorder.dart';
import 'session_list_page.dart';
import 'settings_sheet.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.recorder});

  final Recorder recorder;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _promptCtrl = TextEditingController();

  Recorder get _rec => widget.recorder;

  @override
  void initState() {
    super.initState();
    _rec.addListener(_onChange);
  }

  @override
  void dispose() {
    _rec.removeListener(_onChange);
    _promptCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleRecord() async {
    if (_rec.isRecording) {
      final path = await _rec.stop();
      if (mounted && path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存: ${_rec.sessionId ?? path}')),
        );
      }
    } else {
      try {
        await _rec.start(initialPrompt: _promptCtrl.text);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('開始失敗: $e')));
        }
      }
    }
  }

  Future<void> _talkDown(_) => _rec.beginTalk();

  Future<void> _talkUp(_) async {
    await _rec.endTalk(prompt: _promptCtrl.text);
    _promptCtrl.clear();
  }

  void _addTextLabel() {
    _rec.addTextLabel(_promptCtrl.text);
    _promptCtrl.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec.isRecording;
    final controller = _rec.camera.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('VLA Logger'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: 'セッション',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SessionListPage(recorder: _rec),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '設定',
            onPressed: rec ? null : () => showSettingsSheet(context, _rec),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: controller != null && controller.value.isInitialized
                  ? CameraPreview(controller)
                  : const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
            ),
          ),
          _StatusBar(recorder: _rec),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _promptCtrl,
                  decoration: InputDecoration(
                    labelText: rec ? '途中経過ラベル（任意）' : '初期ラベル（任意）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addTextLabel(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: rec ? _addTextLabel : null,
                        icon: const Icon(Icons.label_outline),
                        label: const Text('ラベル追加'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTapDown: rec ? _talkDown : null,
                        onTapUp: rec ? _talkUp : null,
                        onTapCancel: rec ? () => _talkUp(null) : null,
                        child: Container(
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _rec.isTalking
                                ? Colors.black
                                : Colors.transparent,
                            border: Border.all(color: Colors.black),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _rec.isTalking ? '● 録音中…' : '押して音声メモ',
                            style: TextStyle(
                              color: _rec.isTalking
                                  ? Colors.white
                                  : (rec ? Colors.black : Colors.grey),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: rec ? Colors.white : Colors.black,
                      foregroundColor: rec ? Colors.black : Colors.white,
                      side: const BorderSide(color: Colors.black),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    onPressed: _toggleRecord,
                    child: Text(rec ? '■ 録画停止' : '● 録画開始'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 録画状態・セッション ID・設定レートを 1 行で表示する銘板。
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.recorder});

  final Recorder recorder;

  @override
  Widget build(BuildContext context) {
    final c = recorder.config;
    final text = recorder.isRecording
        ? 'REC  ${recorder.sessionId}'
        : 'IDLE  cam ${c.cameraHz}Hz / imu ${c.imuHz}Hz / gnss ${c.gnssHz}Hz';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: recorder.isRecording ? Colors.black : Colors.grey.shade200,
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: recorder.isRecording ? Colors.white : Colors.black87,
        ),
      ),
    );
  }
}
