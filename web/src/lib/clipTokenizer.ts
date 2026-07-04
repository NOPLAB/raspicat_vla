/**
 * CLIP (ViT-B/32) の BPE トークナイザ。`clip.tokenize` と一致させる。
 * `app/lib/src/clip_tokenizer.dart` の移植 (= OpenAI CLIP SimpleTokenizer)。
 *
 * 語彙は `/clip/bpe_simple_vocab_16e6.txt.gz` を fetch + DecompressionStream で
 * 展開する。未配置なら ready = false になり、呼び出し側は text ゴール特徴を
 * ゼロ扱いにフォールバックする。
 */

import { withBase } from './baseUrl';
import { OmniVlaConfig } from './config';

const VOCAB_URL = withBase('/clip/bpe_simple_vocab_16e6.txt.gz');

/** CLIP 既定の EOT id (語彙未ロード時のフォールバック)。 */
const DEFAULT_EOT = 49407;

export class ClipTokenizer {
  private byteEncoder = bytesToUnicode();
  private encoder = new Map<string, number>();
  private bpeRanks = new Map<string, number>();
  private cache = new Map<string, string>();
  private sot = 0;
  private eot = DEFAULT_EOT;
  private isReady = false;

  /** CLIP の単語分割パターン (unicode / 大文字小文字無視)。 */
  private static readonly PAT =
    /<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+/giu;

  get ready(): boolean {
    return this.isReady;
  }

  get eotToken(): number {
    return this.eot;
  }

  async init(vocabUrl: string = VOCAB_URL): Promise<void> {
    try {
      const resp = await fetch(vocabUrl);
      if (!resp.ok || !resp.body) throw new Error(`HTTP ${resp.status}`);
      const text = await new Response(
        resp.body.pipeThrough(new DecompressionStream('gzip')),
      ).text();
      this.buildFromText(text);
    } catch {
      this.isReady = false;
    }
  }

  /** 展開済み語彙テキストから構築する (テスト用に公開)。 */
  buildFromText(vocabText: string): void {
    // OpenAI CLIP と同じく merges[1 : 49152-256-2+1] を採用 = 48894 要素。
    const lines = vocabText.split('\n');
    const numMerges = 49152 - 256 - 2 + 1 - 1; // 48894
    const merges = lines.slice(1, 1 + numMerges);

    const vocab: string[] = [...this.byteEncoder.values()];
    vocab.push(...[...this.byteEncoder.values()].map((v) => `${v}</w>`));
    for (const m of merges) {
      vocab.push(m.split(' ').join(''));
    }
    vocab.push('<|startoftext|>', '<|endoftext|>');

    this.encoder.clear();
    for (let i = 0; i < vocab.length; i++) {
      this.encoder.set(vocab[i], i);
    }
    this.bpeRanks.clear();
    for (let i = 0; i < merges.length; i++) {
      this.bpeRanks.set(merges[i], i);
    }
    const sot = this.encoder.get('<|startoftext|>');
    const eot = this.encoder.get('<|endoftext|>');
    if (sot === undefined || eot === undefined) {
      throw new Error('CLIP vocab に SOT/EOT トークンがありません');
    }
    this.sot = sot;
    this.eot = eot;
    this.cache.clear();
    this.isReady = true;
  }

  /** text -> 長さ 77 の Int32Array (token ids)。ready でないと全ゼロ。 */
  tokenize(text: string): Int32Array {
    const ctx = OmniVlaConfig.clipContextLength;
    const out = new Int32Array(ctx);
    if (!this.isReady) return out;

    const tokens: number[] = [this.sot];
    const cleaned = text.trim().toLowerCase().replace(/\s+/g, ' ');
    for (const match of cleaned.matchAll(ClipTokenizer.PAT)) {
      const token = match[0];
      const bytes = new TextEncoder().encode(token);
      let mapped = '';
      for (const b of bytes) {
        // byteEncoder は 0..255 を網羅するので必ずヒットする。
        mapped += this.byteEncoder.get(b) ?? '';
      }
      for (const bpeTok of this.bpe(mapped).split(' ')) {
        const id = this.encoder.get(bpeTok);
        if (id !== undefined) tokens.push(id);
      }
    }
    tokens.push(this.eot);

    // truncate (末尾を EOT に) / pad(0)。
    if (tokens.length > ctx) {
      for (let i = 0; i < ctx; i++) out[i] = tokens[i];
      out[ctx - 1] = this.eot;
    } else {
      for (let i = 0; i < tokens.length; i++) out[i] = tokens[i];
    }
    return out;
  }

  private bpe(token: string): string {
    const cached = this.cache.get(token);
    if (cached !== undefined) return cached;
    if (token.length === 0) return token;

    // word: 各文字 (コードポイント単位)。末尾に </w> を付与。
    let word = [...token];
    word[word.length - 1] = `${word[word.length - 1]}</w>`;

    let pairs = getPairs(word);
    if (pairs.size === 0) {
      const res = `${token}</w>`;
      this.cache.set(token, res);
      return res;
    }

    for (;;) {
      let best: string | null = null;
      let bestRank = Infinity;
      for (const p of pairs) {
        const r = this.bpeRanks.get(p);
        if (r !== undefined && r < bestRank) {
          bestRank = r;
          best = p;
        }
      }
      if (best === null) break;

      const sp = best.indexOf(' ');
      const first = best.slice(0, sp);
      const second = best.slice(sp + 1);
      const newWord: string[] = [];
      let i = 0;
      while (i < word.length) {
        const j = word.indexOf(first, i);
        if (j < 0) {
          newWord.push(...word.slice(i));
          break;
        }
        newWord.push(...word.slice(i, j));
        if (
          word[j] === first &&
          j < word.length - 1 &&
          word[j + 1] === second
        ) {
          newWord.push(first + second);
          i = j + 2;
        } else {
          newWord.push(word[j]);
          i = j + 1;
        }
      }
      word = newWord;
      if (word.length === 1) break;
      pairs = getPairs(word);
    }

    const res = word.join(' ');
    this.cache.set(token, res);
    return res;
  }
}

function getPairs(word: string[]): Set<string> {
  const pairs = new Set<string>();
  for (let i = 0; i < word.length - 1; i++) {
    pairs.add(`${word[i]} ${word[i + 1]}`);
  }
  return pairs;
}

/** GPT-2/CLIP の bytes_to_unicode。 */
function bytesToUnicode(): Map<number, string> {
  const bs: number[] = [];
  for (let i = '!'.charCodeAt(0); i <= '~'.charCodeAt(0); i++) bs.push(i);
  for (let i = '¡'.charCodeAt(0); i <= '¬'.charCodeAt(0); i++) bs.push(i);
  for (let i = '®'.charCodeAt(0); i <= 'ÿ'.charCodeAt(0); i++) bs.push(i);

  const cs = [...bs];
  let n = 0;
  for (let b = 0; b < 256; b++) {
    if (!bs.includes(b)) {
      bs.push(b);
      cs.push(256 + n);
      n += 1;
    }
  }
  const map = new Map<number, string>();
  for (let i = 0; i < bs.length; i++) {
    map.set(bs[i], String.fromCharCode(cs[i]));
  }
  return map;
}
