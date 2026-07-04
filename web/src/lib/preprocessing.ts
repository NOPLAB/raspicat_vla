/**
 * 前処理: リサイズ / ImageNet 正規化 / リングバッファ / ゴール tensor。
 *
 * `app/lib/src/preprocessing.dart` (= `omnivla_edge_engine.py`) の移植:
 *  - `_normalize_chw`     -> normalizeChw
 *  - `_black_chw`         -> blackChw
 *  - `_pose_goal_vector`  -> poseGoalVector
 *  - リングバッファ        -> ObsRingBuffer
 *
 * リサイズは canvas の drawImage を使わない: ブラウザ実装ごとに補間が異なり
 * PyTorch 参照とのゴールデン一致が壊れるため、cv2.INTER_AREA 相当の面積平均を
 * 自前実装する (2Hz・96/224px なので CPU で足りる)。
 *
 * 出力はすべて CHW・float32・flatten 済み。ONNX 入力にそのまま渡せる。
 */

import { OmniVlaConfig } from './config';

/** RGBA 画素バッファ。ブラウザの ImageData と構造互換 (テストは node で回すため独自型)。 */
export interface RgbaImage {
  width: number;
  height: number;
  /** RGBA interleaved, 長さ width*height*4。 */
  data: Uint8ClampedArray | Uint8Array;
}

/**
 * RGBA [src] を dstW×dstH に面積平均 (cv2.INTER_AREA 相当) で縮小し、
 * RGB interleaved の uint8 (丸め済み) を返す。拡大方向でも同じ重み計算で
 * 動く (≒box 補間) が、想定入力 (>=240px) では縮小のみ。
 */
export function areaResizeRgb(
  src: RgbaImage,
  dstW: number,
  dstH: number,
): Uint8Array {
  const { width: sw, height: sh, data } = src;
  const out = new Uint8Array(dstW * dstH * 3);
  const sx = sw / dstW;
  const sy = sh / dstH;
  const invArea = 1 / (sx * sy);

  for (let dy = 0; dy < dstH; dy++) {
    const y0 = dy * sy;
    const y1 = y0 + sy;
    const iy0 = Math.floor(y0);
    const iy1 = Math.min(Math.ceil(y1), sh);
    for (let dx = 0; dx < dstW; dx++) {
      const x0 = dx * sx;
      const x1 = x0 + sx;
      const ix0 = Math.floor(x0);
      const ix1 = Math.min(Math.ceil(x1), sw);

      let r = 0;
      let g = 0;
      let b = 0;
      for (let yy = iy0; yy < iy1; yy++) {
        const wy = Math.min(yy + 1, y1) - Math.max(yy, y0);
        const rowBase = yy * sw;
        for (let xx = ix0; xx < ix1; xx++) {
          const wx = Math.min(xx + 1, x1) - Math.max(xx, x0);
          const w = wx * wy;
          const p = (rowBase + xx) * 4;
          r += data[p] * w;
          g += data[p + 1] * w;
          b += data[p + 2] * w;
        }
      }
      const o = (dy * dstW + dx) * 3;
      out[o] = clampByte(Math.round(r * invArea));
      out[o + 1] = clampByte(Math.round(g * invArea));
      out[o + 2] = clampByte(Math.round(b * invArea));
    }
  }
  return out;
}

function clampByte(v: number): number {
  return v < 0 ? 0 : v > 255 ? 255 : v;
}

/** RGBA [src] を size×size にリサイズし ImageNet 正規化した CHW float32 (長さ 3*size*size)。 */
export function normalizeChw(src: RgbaImage, size: number): Float32Array {
  const rgb =
    src.width === size && src.height === size
      ? extractRgb(src)
      : areaResizeRgb(src, size, size);

  const area = size * size;
  const out = new Float32Array(3 * area);
  const [mr, mg, mb] = OmniVlaConfig.imagenetMean;
  const [sr, sg, sb] = OmniVlaConfig.imagenetStd;
  for (let i = 0; i < area; i++) {
    const p = i * 3;
    out[i] = (rgb[p] / 255 - mr) / sr; // R plane
    out[area + i] = (rgb[p + 1] / 255 - mg) / sg; // G plane
    out[2 * area + i] = (rgb[p + 2] / 255 - mb) / sb; // B plane
  }
  return out;
}

function extractRgb(src: RgbaImage): Uint8Array {
  const n = src.width * src.height;
  const out = new Uint8Array(n * 3);
  for (let i = 0; i < n; i++) {
    out[i * 3] = src.data[i * 4];
    out[i * 3 + 1] = src.data[i * 4 + 1];
    out[i * 3 + 2] = src.data[i * 4 + 2];
  }
  return out;
}

/** ImageNet 正規化された全黒 (3, size, size)。衛星マップ/ゴール画像のゼロ埋め。 */
export function blackChw(size: number): Float32Array {
  const area = size * size;
  const out = new Float32Array(3 * area);
  for (let c = 0; c < 3; c++) {
    const v =
      (0 - OmniVlaConfig.imagenetMean[c]) / OmniVlaConfig.imagenetStd[c];
    out.fill(v, c * area, (c + 1) * area);
  }
  return out;
}

/**
 * pose ゴール (ロボット相対 [x, y, theta]) から (4,) の goal_pose ベクトルを作る。
 * `_pose_goal_vector` と一致: `(x_fwd/spacing, y_left/spacing, cos, sin)`。
 * 半径を goalDistThresholdM でクランプ。
 */
export function poseGoalVector(
  xyTheta: readonly [number, number, number],
): Float32Array {
  let [xFwd, yLeft] = xyTheta;
  const theta = xyTheta[2];
  const radius = Math.hypot(xFwd, yLeft);
  if (radius > OmniVlaConfig.goalDistThresholdM) {
    const scale = OmniVlaConfig.goalDistThresholdM / radius;
    xFwd *= scale;
    yLeft *= scale;
  }
  const spacing = OmniVlaConfig.metricWaypointSpacing;
  return Float32Array.of(
    xFwd / spacing,
    yLeft / spacing,
    Math.cos(theta),
    Math.sin(theta),
  );
}

/**
 * 観測履歴のリングバッファ。各フレームは正規化済み CHW (3, obsSize, obsSize)。
 * 古い順・現在最後。不足時は最古フレームで前詰め (cold-start)。
 */
export class ObsRingBuffer {
  private frames: Float32Array[] = [];
  private readonly capacity = OmniVlaConfig.historyLen;
  private readonly frameLen = 3 * OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;

  get isEmpty(): boolean {
    return this.frames.length === 0;
  }

  reset(): void {
    this.frames = [];
  }

  /** 正規化済み現在フレーム (長さ 3*96*96) を push。 */
  push(frameChw: Float32Array): void {
    if (frameChw.length !== this.frameLen) {
      throw new Error(`frame length ${frameChw.length} != ${this.frameLen}`);
    }
    this.frames.push(frameChw);
    if (this.frames.length > this.capacity) {
      this.frames.shift();
    }
  }

  /** 直近フレーム (現在) の CHW。map_images 構築に使う。 */
  get current(): Float32Array {
    const last = this.frames[this.frames.length - 1];
    if (!last) throw new Error('no observation frames buffered yet');
    return last;
  }

  /** (1, 3*historyLen, 96, 96) を flatten した Float32Array。古い順・前詰め。 */
  stack(): Float32Array {
    if (this.frames.length === 0)
      throw new Error('no observation frames buffered yet');
    const out = new Float32Array(this.capacity * this.frameLen);
    const deficit = this.capacity - this.frames.length;
    let offset = 0;
    for (let i = 0; i < this.capacity; i++) {
      const frame = this.frames[Math.max(0, i - deficit)];
      out.set(frame, offset);
      offset += this.frameLen;
    }
    return out;
  }
}
