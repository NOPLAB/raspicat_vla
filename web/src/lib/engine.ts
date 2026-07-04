/**
 * OmniVlaEngine — ブラウザ上の推論オーケストレーション。
 * `app/lib/src/omnivla_engine.dart` (= omnivla_edge_engine.py の infer_chunk) の移植:
 *  1. 現在フレームを正規化しリングバッファへ push
 *  2. 7 入力 tensor を組み立て (docs/design/mobile_port_spec.md §3.1)
 *  3. CLIP text 特徴をプロンプト単位でキャッシュ
 *  4. ONNX 本体を実行し action chunk (8,4) を得る
 *
 * ONNX 資産が未配置なら OrtRunner が null を返すので、動作確認用のダミー
 * 軌道 (ゴールへ緩く向かう前進弧) にフォールバックする。
 */

import { ActionChunk } from './actionChunk';
import { ClipTokenizer } from './clipTokenizer';
import { OmniVlaConfig } from './config';
import type { Goal } from './goal';
import { modalityId } from './goal';
import { type Ep, type OrtInitProgress, OrtRunner } from './ortRunner';
import {
  blackChw,
  normalizeChw,
  ObsRingBuffer,
  poseGoalVector,
  type RgbaImage,
} from './preprocessing';

export type { OrtInitProgress };

export class OmniVlaEngine {
  private readonly runner: OrtRunner;
  private readonly tokenizer: ClipTokenizer;
  private readonly ring = new ObsRingBuffer();
  private readonly black96 = blackChw(OmniVlaConfig.obsSize);

  // CLIP text 特徴のキャッシュ (プロンプト単位)。
  private textCacheKey: string | null = null;
  private textCacheFeat: Float32Array | null = null;

  constructor(runner?: OrtRunner, tokenizer?: ClipTokenizer) {
    this.runner = runner ?? new OrtRunner();
    this.tokenizer = tokenizer ?? new ClipTokenizer();
  }

  get modelAvailable(): boolean {
    return this.runner.modelAvailable;
  }

  get textEncoderReady(): boolean {
    return this.runner.textAvailable && this.tokenizer.ready;
  }

  get ep(): Ep | null {
    return this.runner.ep;
  }

  get lastError(): string {
    return this.runner.lastError;
  }

  async init(onProgress?: (p: OrtInitProgress) => void): Promise<void> {
    await this.runner.init(onProgress);
    await this.tokenizer.init();
  }

  /** ゴール切替時など履歴を破棄する。 */
  reset(): void {
    this.ring.reset();
    this.textCacheKey = null;
    this.textCacheFeat = null;
  }

  /** 1 フレーム分の推論。curRgb は RGBA (FOV 調整=中央クロップ済み)。 */
  async inferChunk(curRgb: RgbaImage, goal: Goal): Promise<ActionChunk> {
    // 1. 観測履歴。
    this.ring.push(normalizeChw(curRgb, OmniVlaConfig.obsSize));
    const obsImages = this.ring.stack(); // (1,18,96,96)
    const curLarge = normalizeChw(curRgb, OmniVlaConfig.largeSize);

    // 2. ゴール tensor。
    const goalPose =
      goal.mode === 'pose' && goal.poseXyTheta
        ? poseGoalVector(goal.poseXyTheta)
        : new Float32Array(OmniVlaConfig.actionDim);

    const goalImage =
      goal.mode === 'image' && goal.image
        ? normalizeChw(goal.image, OmniVlaConfig.obsSize)
        : this.black96;

    // map_images = cat(black, black, obs_image_cur) -> (1,9,96,96)
    const area = OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;
    const mapImages = new Float32Array(9 * area);
    mapImages.set(this.black96, 0);
    mapImages.set(this.black96, 3 * area);
    mapImages.set(this.ring.current, 6 * area);

    // 3. text 特徴 (キャッシュ)。
    const featText = await this.textFeatures(
      goal.mode === 'text' ? goal.text : '',
    );

    // 4. 推論 (未配置ならダミー)。
    const out = await this.runner.runModel({
      obsImages,
      goalPose,
      mapImages,
      goalImage,
      modalityId: modalityId(goal.mode),
      featText,
      curLarge,
    });
    // 数値ガード: 非有限/桁あふれが waypoint を画面外へ飛ばすのを防ぐ。
    if (
      out !== null &&
      out.length === OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim &&
      isSane(out)
    ) {
      return new ActionChunk(out, true);
    }
    return this.dummyChunk(goal);
  }

  private async textFeatures(text: string): Promise<Float32Array> {
    if (text === this.textCacheKey && this.textCacheFeat !== null) {
      return this.textCacheFeat;
    }
    let feat: Float32Array = new Float32Array(OmniVlaConfig.clipTextDim); // 既定ゼロ
    if (this.tokenizer.ready) {
      const tokens = this.tokenizer.tokenize(text.length === 0 ? 'xxxx' : text);
      // EOT トークンの位置 (ArgMax の代替として ONNX に渡す)。
      let eotIndex = tokens.indexOf(this.tokenizer.eotToken);
      if (eotIndex < 0) eotIndex = tokens.length - 1;
      const encoded = await this.runner.encodeText(tokens, eotIndex);
      if (encoded !== null && encoded.length === OmniVlaConfig.clipTextDim) {
        feat = encoded;
      }
    }
    this.textCacheKey = text;
    this.textCacheFeat = feat;
    return feat;
  }

  /** モデル未配置時の可視化用ダミー: ゴール方向へ緩く前進する弧。 */
  private dummyChunk(goal: Goal): ActionChunk {
    let heading = 0; // rad, 左が正
    if (goal.mode === 'pose' && goal.poseXyTheta) {
      heading = Math.atan2(goal.poseXyTheta[1], goal.poseXyTheta[0]);
    } else {
      // text/image はデモ用に軽く蛇行。
      heading = 0.2 * Math.sin(Date.now() / 1000);
    }
    heading = Math.max(-0.6, Math.min(0.6, heading));

    const raw = new Float32Array(
      OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim,
    );
    let x = 0;
    let y = 0;
    let th = 0;
    for (let i = 0; i < OmniVlaConfig.lenTrajPred; i++) {
      th += heading / OmniVlaConfig.lenTrajPred;
      x += Math.cos(th); // 前進 1 unit
      y += Math.sin(th);
      const o = i * OmniVlaConfig.actionDim;
      raw[o] = x;
      raw[o + 1] = y;
      raw[o + 2] = Math.cos(th);
      raw[o + 3] = Math.sin(th);
    }
    return new ActionChunk(raw, false);
  }

  async dispose(): Promise<void> {
    await this.runner.dispose();
  }
}

/** waypoint 値が有限かつ妥当な範囲 (|v| < 1e4 spacing 単位) か。 */
function isSane(v: Float32Array): boolean {
  for (const x of v) {
    if (!Number.isFinite(x) || Math.abs(x) > 1e4) return false;
  }
  return true;
}
