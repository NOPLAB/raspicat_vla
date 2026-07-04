/**
 * onnxruntime-web ラッパー: OmniVLA-edge 本体 + CLIP text encoder。
 * `app/lib/src/inference/ort_runner.dart` の移植。
 *
 * EP は WebGPU を優先し、使えなければ wasm へフォールバックする。wasm 時は
 * `ort.env.wasm.proxy = true` で worker 実行にし UI スレッドを塞がない
 * (Flutter 版の runAsync に相当)。ランタイムの .wasm/.mjs は postinstall が
 * public/ort/ へコピーしたものを参照する。
 *
 * モデル未配置 (404) でも UI が動くよう、ロード失敗時は modelAvailable /
 * textAvailable を false にし、呼び出し側 (OmniVlaEngine) がダミー軌道へ
 * フォールバックする。
 */

import type { InferenceSession, Tensor } from 'onnxruntime-web';

import { withBase } from './baseUrl';
import { OmniVlaConfig } from './config';
import { type FetchProgress, fetchModelCached } from './modelStore';

// export 時に確定した 7 入力名 (docs/design/mobile_port_spec.md §3.1)。
const MODEL_INPUT_NAMES = {
  obsImages: 'obs_images',
  goalPose: 'goal_pose',
  mapImages: 'map_images',
  goalImage: 'goal_image',
  modalityId: 'modality_id',
  featText: 'feat_text',
  curLarge: 'cur_large',
} as const;

const MODEL_URL = withBase('/models/omnivla_edge.onnx');
const TEXT_URL = withBase('/models/clip_text.onnx');
const TEXT_INPUT_NAME = 'tokens';
const EOT_INPUT_NAME = 'eot_index';

// ORT はバンドルせず、postinstall が public/ort/ へ置いた ESM を実行時 import する。
// バンドル経由だと wasm proxy worker が import.meta.url を解決できず
// "worker not ready" で死ぬ (Next/webpack の chunk URL になるため)。
const ORT_ESM_URL = withBase('/ort/ort.all.min.mjs');

export type Ep = 'webgpu' | 'wasm';

export interface OrtInitProgress {
  /** 例: "omnivla_edge.onnx を取得中"。 */
  stage: string;
  fetch?: FetchProgress;
}

type OrtModule = typeof import('onnxruntime-web');

export class OrtRunner {
  private ort: OrtModule | null = null;
  private model: InferenceSession | null = null;
  private text: InferenceSession | null = null;

  /** 実際に使われた EP (両セッション共通)。 */
  ep: Ep | null = null;
  /** init で事前判定した EP 候補 (優先順)。 */
  private candidates: Ep[] = ['wasm'];
  /** ロード失敗の理由 (UI/診断用)。 */
  lastError = '';

  get modelAvailable(): boolean {
    return this.model !== null;
  }

  get textAvailable(): boolean {
    return this.text !== null;
  }

  async init(onProgress?: (p: OrtInitProgress) => void): Promise<void> {
    const ort = (await import(
      /* webpackIgnore: true */ ORT_ESM_URL
    )) as unknown as OrtModule;
    this.ort = ort;
    ort.env.wasm.wasmPaths = withBase('/ort/');
    // COOP/COEP なしの静的配信では SharedArrayBuffer が使えない。
    if (typeof crossOriginIsolated !== 'undefined' && !crossOriginIsolated) {
      ort.env.wasm.numThreads = 1;
    }

    // EP は最初の create 前に確定させる。ort.env.wasm.* は wasm コア初期化後に
    // 変更しても効かず、後から proxy を立てると "worker not ready" で死ぬ。
    // navigator.gpu はアダプタが取れない環境 (headless 等) でも生えているので、
    // requestAdapter() の実結果で判定する。
    this.candidates = await detectEpCandidates();
    if (this.candidates[0] === 'wasm') {
      // wasm 主経路: 実行を worker へ (UI スレッド保護)。
      ort.env.wasm.proxy = true;
    }

    const modelBytes = await fetchModelCached(MODEL_URL, (fetch) =>
      onProgress?.({ stage: 'omnivla_edge.onnx を取得中', fetch }),
    );
    if (modelBytes) {
      onProgress?.({
        stage: 'omnivla_edge.onnx セッションを構築中 (初回は時間がかかります)',
      });
      this.model = await this.createSession(modelBytes);
    } else {
      this.lastError = `${MODEL_URL}: 取得失敗 (未配置?)`;
    }

    const textBytes = await fetchModelCached(TEXT_URL, (fetch) =>
      onProgress?.({ stage: 'clip_text.onnx を取得中', fetch }),
    );
    if (textBytes) {
      onProgress?.({ stage: 'clip_text.onnx セッションを構築中' });
      this.text = await this.createSession(textBytes);
    }
  }

  /** 事前判定した候補の順でセッション生成を試みる。EP は最初に成功したものに固定。 */
  private async createSession(
    bytes: Uint8Array,
  ): Promise<InferenceSession | null> {
    const ort = this.ort;
    if (!ort) return null;
    // 2 個目のセッションは 1 個目と同じ EP に揃える。
    const candidates: Ep[] = this.ep !== null ? [this.ep] : this.candidates;

    for (const ep of candidates) {
      try {
        const session = await ort.InferenceSession.create(bytes, {
          executionProviders: [ep],
          graphOptimizationLevel: 'all',
        });
        this.ep = ep;
        return session;
      } catch (e) {
        // webgpu が事前判定を通ったのに落ちた場合のみここへ来る。wasm へは
        // proxy なし (メインスレッド) で落とす — wasm コアは既に初期化済みで
        // env の変更が効かないため、劣化はするが確実に動く方を取る。
        this.lastError = `EP ${ep}: ${e instanceof Error ? e.message : e}`;
      }
    }
    return null;
  }

  /**
   * CLIP トークン列 (長さ 77) を 512 次元特徴へ。eotIndex は EOT トークンの
   * 位置 (ArgMax の代替として ONNX に渡す)。未ロード時 null。
   */
  async encodeText(
    tokens: Int32Array,
    eotIndex: number,
  ): Promise<Float32Array | null> {
    const session = this.text;
    const ort = this.ort;
    if (!session || !ort) return null;

    const feeds: Record<string, Tensor> = {
      [TEXT_INPUT_NAME]: new ort.Tensor(
        'int64',
        BigInt64Array.from(tokens as unknown as ArrayLike<number>, (t) =>
          BigInt(t),
        ),
        [1, OmniVlaConfig.clipContextLength],
      ),
      [EOT_INPUT_NAME]: new ort.Tensor(
        'int64',
        BigInt64Array.of(BigInt(eotIndex)),
        [1],
      ),
    };
    const outputs = await session.run(feeds);
    return toFloat32(outputs[session.outputNames[0]]);
  }

  /** 7 入力を渡し action chunk (flatten 済み 8*4) を返す。未ロード時は null。 */
  async runModel(args: {
    obsImages: Float32Array; // (1,18,96,96)
    goalPose: Float32Array; // (1,4)
    mapImages: Float32Array; // (1,9,96,96)
    goalImage: Float32Array; // (1,3,96,96)
    modalityId: number;
    featText: Float32Array; // (1,512)
    curLarge: Float32Array; // (1,3,224,224)
  }): Promise<Float32Array | null> {
    const session = this.model;
    const ort = this.ort;
    if (!session || !ort) return null;

    const s = OmniVlaConfig.obsSize;
    const l = OmniVlaConfig.largeSize;
    // 必ずコピーを渡す: proxy=true のとき ORT は入力バッファを worker へ
    // transfer し、元の ArrayBuffer が detach される。エンジン側のキャッシュ
    // (black96 / text 特徴) をそのまま包むと 2 回目の推論で壊れる。
    const f32 = (v: Float32Array) => new Float32Array(v);
    const feeds: Record<string, Tensor> = {
      [MODEL_INPUT_NAMES.obsImages]: new ort.Tensor(
        'float32',
        f32(args.obsImages),
        [1, 3 * OmniVlaConfig.historyLen, s, s],
      ),
      [MODEL_INPUT_NAMES.goalPose]: new ort.Tensor(
        'float32',
        f32(args.goalPose),
        [1, 4],
      ),
      [MODEL_INPUT_NAMES.mapImages]: new ort.Tensor(
        'float32',
        f32(args.mapImages),
        [1, 9, s, s],
      ),
      [MODEL_INPUT_NAMES.goalImage]: new ort.Tensor(
        'float32',
        f32(args.goalImage),
        [1, 3, s, s],
      ),
      [MODEL_INPUT_NAMES.modalityId]: new ort.Tensor(
        'int64',
        BigInt64Array.of(BigInt(args.modalityId)),
        [1],
      ),
      [MODEL_INPUT_NAMES.featText]: new ort.Tensor(
        'float32',
        f32(args.featText),
        [1, OmniVlaConfig.clipTextDim],
      ),
      [MODEL_INPUT_NAMES.curLarge]: new ort.Tensor(
        'float32',
        f32(args.curLarge),
        [1, 3, l, l],
      ),
    };
    // 出力先頭が action_pred (1, 8, 4) 想定 (ort_runner.dart と同じ)。
    const outputs = await session.run(feeds);
    return toFloat32(outputs[session.outputNames[0]]);
  }

  async dispose(): Promise<void> {
    await this.model?.release();
    await this.text?.release();
    this.model = null;
    this.text = null;
  }
}

/** WebGPU が本当に使えるか (アダプタ取得まで) を確認して EP 候補を返す。 */
async function detectEpCandidates(): Promise<Ep[]> {
  if (typeof navigator !== 'undefined' && 'gpu' in navigator) {
    try {
      const adapter = await (
        navigator as Navigator & { gpu: { requestAdapter(): Promise<unknown> } }
      ).gpu.requestAdapter();
      if (adapter) return ['webgpu', 'wasm'];
    } catch {
      // WebGPU 不可 -> wasm へ。
    }
  }
  return ['wasm'];
}

function toFloat32(t: Tensor | undefined): Float32Array | null {
  if (!t) return null;
  const data = t.data;
  if (data instanceof Float32Array) return new Float32Array(data);
  // fp16 等で返るケースの保険。数値配列なら変換する。
  if (ArrayBuffer.isView(data)) {
    return Float32Array.from(data as unknown as ArrayLike<number>);
  }
  return null;
}
