/// 収集済みセッションの一覧と転送 (ローカル zip / Google Drive)。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../recorder.dart';
import '../transfer/drive_uploader.dart';
import '../transfer/zip_exporter.dart';

class SessionListPage extends StatefulWidget {
  const SessionListPage({super.key, required this.recorder});

  final Recorder recorder;

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  final DriveUploader _drive = DriveUploader();
  List<Directory> _sessions = [];
  String? _busy; // 処理中セッション ID

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = Directory(
      p.join(widget.recorder.baseDir.path, 'logger_sessions'),
    );
    final list = <Directory>[];
    if (await root.exists()) {
      await for (final e in root.list()) {
        if (e is Directory) list.add(e);
      }
      list.sort((a, b) => b.path.compareTo(a.path));
    }
    if (mounted) setState(() => _sessions = list);
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _exportLocal(Directory dir) async {
    setState(() => _busy = p.basename(dir.path));
    try {
      final zip = await exportSessionZip(dir);
      _snack('zip 保存: ${zip.path}');
    } catch (e) {
      _snack('zip 失敗: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _uploadDrive(Directory dir) async {
    setState(() => _busy = p.basename(dir.path));
    try {
      if (!_drive.isSignedIn) {
        await _drive.signIn();
      }
      final zip = await exportSessionZip(dir);
      final id = await _drive.uploadZip(
        zip,
        folderId: widget.recorder.config.driveFolderId,
      );
      _snack('Drive 送信完了 (id: $id)');
    } catch (e) {
      _snack('Drive 失敗: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _sessions.isEmpty
          ? const Center(child: Text('セッションはまだありません'))
          : ListView.separated(
              itemCount: _sessions.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final dir = _sessions[i];
                final id = p.basename(dir.path);
                final busy = _busy == id;
                return ListTile(
                  title: Text(
                    id,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  subtitle: _busy != null && busy ? const Text('処理中…') : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.archive_outlined),
                        tooltip: 'zip 保存',
                        onPressed: _busy == null
                            ? () => _exportLocal(dir)
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.cloud_upload_outlined),
                        tooltip: 'Drive 送信',
                        onPressed: _busy == null
                            ? () => _uploadDrive(dir)
                            : null,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
