// CLIP BPE の構造検証。実語彙 (app/assets/clip) があれば読み込んで使う。
// 完全なゴールデン照合 (Python clip.tokenize との突き合わせ) は Phase 2 と同様
// GPU 環境側の参照実装で行う。
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';

import { describe, expect, it } from 'vitest';

import { ClipTokenizer } from '@/lib/clipTokenizer';
import { OmniVlaConfig } from '@/lib/config';

const here = path.dirname(fileURLToPath(import.meta.url));
const vocabPath = path.resolve(here, '../../app/assets/clip/bpe_simple_vocab_16e6.txt.gz');
const hasVocab = existsSync(vocabPath);

const SOT = 49406;
const EOT = 49407;

function loadTokenizer(): ClipTokenizer {
  const t = new ClipTokenizer();
  t.buildFromText(gunzipSync(readFileSync(vocabPath)).toString('utf8'));
  return t;
}

describe('ClipTokenizer', () => {
  it('未ロード時は ready=false / 全ゼロ / 既定 EOT', () => {
    const t = new ClipTokenizer();
    expect(t.ready).toBe(false);
    expect(t.eotToken).toBe(EOT);
    expect([...t.tokenize('hello')]).toEqual(new Array(OmniVlaConfig.clipContextLength).fill(0));
  });

  it.skipIf(!hasVocab)('SOT/EOT/pad の構造と単字トークン', () => {
    const t = loadTokenizer();
    expect(t.ready).toBe(true);
    expect(t.eotToken).toBe(EOT);

    // 単字 'a' の id は bytes_to_unicode 順で 256 + ('a' - '!') = 320。
    const tokens = t.tokenize('a');
    expect(tokens[0]).toBe(SOT);
    expect(tokens[1]).toBe(320);
    expect(tokens[2]).toBe(EOT);
    for (let i = 3; i < tokens.length; i++) expect(tokens[i]).toBe(0);
  });

  it.skipIf(!hasVocab)('大文字小文字・空白正規化で同一トークン列', () => {
    const t = loadTokenizer();
    expect([...t.tokenize('  Go  TO the Door ')]).toEqual([...t.tokenize('go to the door')]);
  });

  it.skipIf(!hasVocab)('長文は 77 に truncate され末尾 EOT', () => {
    const t = loadTokenizer();
    const tokens = t.tokenize(Array(200).fill('navigate').join(' '));
    expect(tokens.length).toBe(OmniVlaConfig.clipContextLength);
    expect(tokens[0]).toBe(SOT);
    expect(tokens[tokens.length - 1]).toBe(EOT);
    expect(tokens[1]).not.toBe(0);
  });
});
