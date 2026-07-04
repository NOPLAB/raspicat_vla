// app/test/widget_test.dart の前処理テストと同等の検証 + 面積平均リサイズ。
import { describe, expect, it } from 'vitest';

import { ActionChunk } from '@/lib/actionChunk';
import { OmniVlaConfig } from '@/lib/config';
import {
  ObsRingBuffer,
  areaResizeRgb,
  blackChw,
  normalizeChw,
  poseGoalVector,
  type RgbaImage,
} from '@/lib/preprocessing';

function solidImage(width: number, height: number, r: number, g: number, b: number): RgbaImage {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    data[i * 4] = r;
    data[i * 4 + 1] = g;
    data[i * 4 + 2] = b;
    data[i * 4 + 3] = 255;
  }
  return { width, height, data };
}

describe('normalizeChw', () => {
  it('CHW・ImageNet 正規化で正しい長さ/値', () => {
    const size = OmniVlaConfig.obsSize;
    const out = normalizeChw(solidImage(size, size, 0, 0, 0), size);
    const area = size * size;
    expect(out.length).toBe(3 * area);
    const expectedR = (0 - OmniVlaConfig.imagenetMean[0]) / OmniVlaConfig.imagenetStd[0];
    expect(out[0]).toBeCloseTo(expectedR, 5);
  });

  it('リサイズを挟んでも一様画像は同じ値', () => {
    const out = normalizeChw(solidImage(480, 480, 128, 64, 200), 96);
    const area = 96 * 96;
    const expectG = (64 / 255 - OmniVlaConfig.imagenetMean[1]) / OmniVlaConfig.imagenetStd[1];
    expect(out[area]).toBeCloseTo(expectG, 5);
    expect(out[2 * area - 1]).toBeCloseTo(expectG, 5);
  });
});

describe('blackChw', () => {
  it('normalizeChw(全黒) と一致', () => {
    const black = blackChw(OmniVlaConfig.obsSize);
    const viaNorm = normalizeChw(
      solidImage(OmniVlaConfig.obsSize, OmniVlaConfig.obsSize, 0, 0, 0),
      OmniVlaConfig.obsSize,
    );
    expect(black.length).toBe(viaNorm.length);
    expect(black[0]).toBeCloseTo(viaNorm[0], 6);
    expect(black[black.length - 1]).toBeCloseTo(viaNorm[viaNorm.length - 1], 6);
  });
});

describe('areaResizeRgb', () => {
  it('整数比の縮小は画素平均 (INTER_AREA)', () => {
    // 2x2 -> 1x1: R = (10+20+30+40)/4 = 25
    const src: RgbaImage = {
      width: 2,
      height: 2,
      data: new Uint8ClampedArray([
        10, 0, 0, 255, 20, 0, 0, 255,
        30, 0, 0, 255, 40, 0, 0, 255,
      ]),
    };
    const out = areaResizeRgb(src, 1, 1);
    expect(out[0]).toBe(25);
  });

  it('非整数比でも部分被覆の重み付き平均になる', () => {
    // 3x1 -> 2x1: 左 = px0 + px1*0.5 (被覆 1.5px), 右 = px1*0.5 + px2
    const src: RgbaImage = {
      width: 3,
      height: 1,
      data: new Uint8ClampedArray([
        0, 0, 0, 255, 90, 0, 0, 255, 30, 0, 0, 255,
      ]),
    };
    const out = areaResizeRgb(src, 2, 1);
    expect(out[0]).toBe(Math.round((0 * 1 + 90 * 0.5) / 1.5)); // 30
    expect(out[3]).toBe(Math.round((90 * 0.5 + 30 * 1) / 1.5)); // 50
  });
});

describe('poseGoalVector', () => {
  it('(x_fwd/s, y_left/s, cos, sin) でクランプ', () => {
    const v = poseGoalVector([2.0, 1.0, 0.0]);
    expect(v[0]).toBeCloseTo(2.0 / OmniVlaConfig.metricWaypointSpacing, 4);
    expect(v[1]).toBeCloseTo(1.0 / OmniVlaConfig.metricWaypointSpacing, 4);
    expect(v[2]).toBeCloseTo(1.0, 6);
    expect(v[3]).toBeCloseTo(0.0, 6);

    const far = poseGoalVector([100.0, 0.0, 0.0]);
    expect(far[0]).toBeCloseTo(OmniVlaConfig.goalDistThresholdM / OmniVlaConfig.metricWaypointSpacing, 2);
  });
});

describe('ObsRingBuffer', () => {
  it('最大 historyLen で前詰め stack', () => {
    const ring = new ObsRingBuffer();
    const area = OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;
    const frame = new Float32Array(3 * area).fill(0.5);
    ring.push(frame);
    const stacked = ring.stack();
    expect(stacked.length).toBe(3 * OmniVlaConfig.historyLen * area);
    expect(stacked[0]).toBeCloseTo(0.5, 6);
    expect(stacked[stacked.length - 1]).toBeCloseTo(0.5, 6);
  });

  it('capacity 超過で最古が捨てられ、古い順に並ぶ', () => {
    const ring = new ObsRingBuffer();
    const area = OmniVlaConfig.obsSize * OmniVlaConfig.obsSize;
    for (let i = 0; i < OmniVlaConfig.historyLen + 2; i++) {
      ring.push(new Float32Array(3 * area).fill(i));
    }
    const stacked = ring.stack();
    expect(stacked[0]).toBe(2); // 最古 (0,1 は押し出された)
    expect(stacked[stacked.length - 1]).toBe(OmniVlaConfig.historyLen + 1); // 現在
  });
});

describe('ActionChunk', () => {
  it('メートル換算を返す', () => {
    const raw = new Float32Array(OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim);
    raw[0] = 10; // x = 10 unit
    const chunk = new ActionChunk(raw, true);
    expect(chunk.xyMetres[0][0]).toBeCloseTo(1.0, 6); // 10 * 0.1m
  });
});
