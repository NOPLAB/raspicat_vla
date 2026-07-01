/// スマホ -> Pi への action chunk 送信経路。
///
/// 重要 (CLAUDE.md / grpc_client.py の性質を踏襲): **coalesce + pace**。
/// 最新の chunk だけを保持し、一定レートでのみ送信する。遅い/切れたリンクが
/// 制御ループを詰まらせないようにするための不変条件。ここでも守る。
///
/// gRPC 実装は proto 生成後 (docs §6 Phase 4) に [GrpcEdgeClient] を差し込む。
/// それまでは [LoggingEdgeClient] で端末内可視化のみ行い、アプリは動く。
library;

import 'dart:async';
import 'dart:typed_data';

import '../action_chunk.dart';

/// fp16 little-endian へパック (proto ActionChunk.values_fp16 用)。
Uint8List packFp16(Float32List values) {
  final bytes = ByteData(values.length * 2);
  for (var i = 0; i < values.length; i++) {
    bytes.setUint16(i * 2, _floatToHalf(values[i]), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// 送信先の抽象。実体は gRPC / ログ / テストダブル。
abstract class EdgeActionClient {
  Future<void> connect();

  /// 1 chunk を送る。frameId / goalId はメタ。
  Future<void> send(ActionChunk chunk, {required int frameId, required String goalId});

  /// 直近の接続/追従ステータス (UI 表示用)。
  String get status;

  Future<void> close();
}

/// 端末内ログのみ。既定。実機 Pi 接続前の動作確認に使う。
class LoggingEdgeClient implements EdgeActionClient {
  String _status = 'logging (no Pi)';
  int _count = 0;

  @override
  Future<void> connect() async {}

  @override
  Future<void> send(ActionChunk chunk, {required int frameId, required String goalId}) async {
    _count++;
    _status = 'sent #$frameId (${chunk.fromModel ? "model" : "dummy"}) x$_count';
  }

  @override
  String get status => _status;

  @override
  Future<void> close() async {}
}

/// 最新 chunk のみ保持し最大レートで送る coalescing/pacing ラッパー。
///
/// [submit] は即時 return (制御ループを塞がない)。実送信は内部タイマで行い、
/// 送信中に来た新しい chunk は古いものを上書きする。
class CoalescingSender {
  CoalescingSender(this._client,
      {this._minInterval = const Duration(milliseconds: 100)});

  final EdgeActionClient _client;
  final Duration _minInterval;

  ActionChunk? _pending;
  int _pendingFrameId = 0;
  String _pendingGoalId = '';
  bool _sending = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  String get status => _client.status;

  /// 送信キューへ投入 (最新のみ保持)。
  void submit(ActionChunk chunk, {required int frameId, required String goalId}) {
    _pending = chunk;
    _pendingFrameId = frameId;
    _pendingGoalId = goalId;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_pending != null) {
        final now = DateTime.now();
        final since = now.difference(_lastSent);
        if (since < _minInterval) {
          await Future<void>.delayed(_minInterval - since);
        }
        final chunk = _pending;
        if (chunk == null) break;
        _pending = null;
        _lastSent = DateTime.now();
        await _client.send(chunk, frameId: _pendingFrameId, goalId: _pendingGoalId);
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> close() => _client.close();
}

// --- IEEE754 float32 -> float16 (half) ---
int _floatToHalf(double value) {
  final f = ByteData(4)..setFloat32(0, value, Endian.little);
  final bits = f.getUint32(0, Endian.little);
  final sign = (bits >> 16) & 0x8000;
  var exp = ((bits >> 23) & 0xff) - 127 + 15;
  var mant = bits & 0x7fffff;
  if (exp <= 0) {
    // subnormal / zero にフラッシュ。
    return sign;
  } else if (exp >= 0x1f) {
    // inf/nan。
    return sign | 0x7c00;
  }
  return sign | (exp << 10) | (mant >> 13);
}
