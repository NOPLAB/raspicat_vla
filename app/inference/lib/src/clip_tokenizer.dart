/// CLIP (ViT-B/32) の BPE トークナイザ。`clip.tokenize` と一致させる。
///
/// 語彙は CLIP 公式の `bpe_simple_vocab_16e6.txt.gz` を
///   assets/clip/bpe_simple_vocab_16e6.txt.gz
/// に配置する (Phase 2)。未配置なら [ready] = false になり、呼び出し側は
/// text ゴール特徴をゼロ扱いにフォールバックする。
///
/// アルゴリズムは OpenAI CLIP `SimpleTokenizer` の移植:
///  bytes_to_unicode -> merges(BPE) -> [SOT] tokens [EOT] を 77 に pad/truncate。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'config.dart';

const _vocabAsset = 'assets/clip/bpe_simple_vocab_16e6.txt.gz';

class ClipTokenizer {
  final Map<int, String> _byteEncoder = _bytesToUnicode();
  final Map<String, int> _encoder = {};
  final Map<String, int> _bpeRanks = {};
  final Map<String, String> _cache = {};
  late final int _sot;
  late final int _eot;
  bool _ready = false;

  bool get ready => _ready;

  /// EOT トークン id (語彙ロード済みなら実値、未ロード時は CLIP 既定 49407)。
  int get eotToken => _ready ? _eot : 49407;

  /// CLIP の単語分割パターン (unicode 対応)。
  static final RegExp _pat = RegExp(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+",
    unicode: true,
    caseSensitive: false,
  );

  Future<void> init() async {
    try {
      final raw = await rootBundle.load(_vocabAsset);
      final gz = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      final text = utf8.decode(gzip.decode(gz));
      _build(text);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  void _build(String vocabText) {
    // OpenAI CLIP と同じく merges[1 : 49152-256-2+1] を採用 = 48894 要素。
    // (skip(1) 後の take は要素数なので end(48895) - start(1) = 48894 個)。
    final lines = const LineSplitter().convert(vocabText);
    final numMerges = (49152 - 256 - 2 + 1) - 1; // 48894
    final merges = lines.skip(1).take(numMerges).toList();

    final vocab = <String>[];
    vocab.addAll(_byteEncoder.values); // 256
    vocab.addAll(_byteEncoder.values.map((v) => '$v</w>')); // 256
    for (final m in merges) {
      vocab.add(m.split(' ').join());
    }
    vocab.add('<|startoftext|>');
    vocab.add('<|endoftext|>');

    for (var i = 0; i < vocab.length; i++) {
      _encoder[vocab[i]] = i;
    }
    for (var i = 0; i < merges.length; i++) {
      _bpeRanks[merges[i]] = i;
    }
    _sot = _encoder['<|startoftext|>']!;
    _eot = _encoder['<|endoftext|>']!;
  }

  /// text -> 長さ 77 の Int32List (token ids)。ready でないと EOT/pad のみ。
  Int32List tokenize(String text) {
    const ctx = OmniVlaConfig.clipContextLength;
    final out = Int32List(ctx);
    if (!_ready) return out;

    final tokens = <int>[_sot];
    final cleaned = _clean(text);
    for (final match in _pat.allMatches(cleaned)) {
      final token = match.group(0)!;
      final bytes = utf8.encode(token);
      final mapped = bytes.map((b) => _byteEncoder[b]!).join();
      for (final bpeTok in _bpe(mapped).split(' ')) {
        final id = _encoder[bpeTok];
        if (id != null) tokens.add(id);
      }
    }
    tokens.add(_eot);

    // truncate (末尾を EOT に) / pad(0)。
    if (tokens.length > ctx) {
      final truncated = tokens.sublist(0, ctx);
      truncated[ctx - 1] = _eot;
      for (var i = 0; i < ctx; i++) {
        out[i] = truncated[i];
      }
    } else {
      for (var i = 0; i < tokens.length; i++) {
        out[i] = tokens[i];
      }
    }
    return out;
  }

  String _clean(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _bpe(String token) {
    final cached = _cache[token];
    if (cached != null) return cached;
    if (token.isEmpty) return token;

    // word: 各文字。末尾に </w> を付与。
    var word = token.split('');
    word[word.length - 1] = '${word.last}</w>';

    var pairs = _getPairs(word);
    if (pairs.isEmpty) {
      final res = '$token</w>';
      _cache[token] = res;
      return res;
    }

    while (true) {
      // 最小ランクの pair を探す。
      String? best;
      var bestRank = 1 << 30;
      for (final p in pairs) {
        final r = _bpeRanks[p];
        if (r != null && r < bestRank) {
          bestRank = r;
          best = p;
        }
      }
      if (best == null) break;

      final parts = best.split(' ');
      final first = parts[0];
      final second = parts[1];
      final newWord = <String>[];
      var i = 0;
      while (i < word.length) {
        final j = _indexOf(word, first, i);
        if (j < 0) {
          newWord.addAll(word.sublist(i));
          break;
        }
        newWord.addAll(word.sublist(i, j));
        if (word[j] == first && j < word.length - 1 && word[j + 1] == second) {
          newWord.add(first + second);
          i = j + 2;
        } else {
          newWord.add(word[j]);
          i = j + 1;
        }
      }
      word = newWord;
      if (word.length == 1) break;
      pairs = _getPairs(word);
    }

    final res = word.join(' ');
    _cache[token] = res;
    return res;
  }

  static int _indexOf(List<String> word, String target, int start) {
    for (var i = start; i < word.length; i++) {
      if (word[i] == target) return i;
    }
    return -1;
  }

  static Set<String> _getPairs(List<String> word) {
    final pairs = <String>{};
    for (var i = 0; i < word.length - 1; i++) {
      pairs.add('${word[i]} ${word[i + 1]}');
    }
    return pairs;
  }

  /// GPT-2/CLIP の bytes_to_unicode。
  static Map<int, String> _bytesToUnicode() {
    final bs = <int>[];
    for (var i = '!'.codeUnitAt(0); i <= '~'.codeUnitAt(0); i++) {
      bs.add(i);
    }
    for (var i = '¡'.codeUnitAt(0); i <= '¬'.codeUnitAt(0); i++) {
      bs.add(i);
    }
    for (var i = '®'.codeUnitAt(0); i <= 'ÿ'.codeUnitAt(0); i++) {
      bs.add(i);
    }
    final cs = List<int>.from(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    final map = <int, String>{};
    for (var i = 0; i < bs.length; i++) {
      map[bs[i]] = String.fromCharCode(cs[i]);
    }
    return map;
  }
}
