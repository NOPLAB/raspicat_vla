/// zip 化したセッションを Google Drive へレジューム対応でアップロードする。
///
/// google_sign_in v7 は認証と認可を分離しているので、authenticate → 必要スコープを
/// authorize → extension の authClient で googleapis 用クライアントを得る、の順。
/// スコープは drive.file (このアプリが作ったファイルのみ) に限定する。
///
/// OAuth クライアント登録は Android (SHA-1 + package 名) と iOS (reversed client ID)
/// で別途必要 (docs/design/logger_app_spec.md §4)。CI/ヘッドレスでは動かない。
library;

import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

/// Drive アップロード担当。[signIn] で一度サインインし、[uploadZip] で送る。
class DriveUploader {
  DriveUploader({this.serverClientId});

  /// Web/サーバ用クライアント ID (任意)。Android/iOS はネイティブ設定を使うので
  /// 通常 null でよい。
  final String? serverClientId;

  static const List<String> _scopes = <String>[drive.DriveApi.driveFileScope];

  GoogleSignInAccount? _account;
  bool _initialized = false;

  bool get isSignedIn => _account != null;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _initialized = true;
  }

  /// 対話サインイン。呼ぶ側はボタン押下などユーザー操作の文脈で呼ぶこと。
  Future<void> signIn() async {
    await _ensureInitialized();
    _account = await GoogleSignIn.instance.authenticate(scopeHint: _scopes);
  }

  Future<void> signOut() async {
    await GoogleSignIn.instance.signOut();
    _account = null;
  }

  /// zip を Drive へアップロードし、作成された Drive ファイル ID を返す。
  /// [folderId] を渡すとそのフォルダ配下に置く。
  Future<String> uploadZip(File zip, {String? folderId}) async {
    final account = _account;
    if (account == null) {
      throw StateError('not signed in');
    }
    // 既存認可を再利用し、無ければ対話で取得する。
    final authz =
        await account.authorizationClient.authorizationForScopes(_scopes) ??
        await account.authorizationClient.authorizeScopes(_scopes);
    final client = authz.authClient(scopes: _scopes);
    try {
      final api = drive.DriveApi(client);
      final meta = drive.File()
        ..name = p.basename(zip.path)
        ..parents = folderId == null ? null : <String>[folderId];
      final media = drive.Media(zip.openRead(), zip.lengthSync());
      final created = await api.files.create(
        meta,
        uploadMedia: media,
        uploadOptions: drive.ResumableUploadOptions(),
      );
      return created.id ?? '';
    } finally {
      client.close();
    }
  }
}
