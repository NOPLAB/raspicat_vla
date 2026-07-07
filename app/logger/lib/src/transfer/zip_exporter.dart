/// セッションディレクトリを zip 化する。
///
/// ローカル保存と Google Drive アップロードの共通入力になる
/// (docs/design/logger_app_spec.md §4)。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// セッションディレクトリを `<baseDir>/exports/<session_id>.zip` に圧縮し、
/// 生成した zip の [File] を返す。
///
/// ZipFileEncoder はファイルを逐次読むのでセッションが大きくてもメモリを食わない
/// が、同期 I/O なので大セッションでは UI をブロックしうる (v1 の割り切り)。
Future<File> exportSessionZip(Directory sessionDir) async {
  final id = p.basename(sessionDir.path);
  final exportsDir = Directory(p.join(sessionDir.parent.parent.path, 'exports'));
  await exportsDir.create(recursive: true);
  final zipPath = p.join(exportsDir.path, '$id.zip');

  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  // zip 内のトップは session_id/ にする。
  await encoder.addDirectory(sessionDir, includeDirName: true);
  await encoder.close();

  return File(zipPath);
}
