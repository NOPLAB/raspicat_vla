/** モデル出力の action chunk (len_traj_pred, 4)。`app/lib/src/action_chunk.dart` の移植。 */

import { OmniVlaConfig } from './config';

/** (numTokens, embedDim) の waypoint 群。raw の x,y は waypoint-spacing 単位。 */
export class ActionChunk {
  /** flatten 済み (8*4)。行 = (x, y, cos, sin), 単位は spacing。 */
  readonly raw: Float32Array;
  /** true=ONNX 実推論, false=ダミー (モデル未配置)。 */
  readonly fromModel: boolean;

  constructor(raw: Float32Array, fromModel = true) {
    const expected = OmniVlaConfig.lenTrajPred * OmniVlaConfig.actionDim;
    if (raw.length !== expected) {
      throw new Error(`chunk length ${raw.length} != ${expected}`);
    }
    this.raw = raw;
    this.fromModel = fromModel;
  }

  get numTokens(): number {
    return OmniVlaConfig.lenTrajPred;
  }

  get embedDim(): number {
    return OmniVlaConfig.actionDim;
  }

  /** 全 waypoint の (x_m, y_m)。x=前方, y=左 (ロボット座標)。 */
  get xyMetres(): Array<[number, number]> {
    const s = OmniVlaConfig.metricWaypointSpacing;
    const out: Array<[number, number]> = [];
    for (let i = 0; i < this.numTokens; i++) {
      const o = i * OmniVlaConfig.actionDim;
      out.push([this.raw[o] * s, this.raw[o + 1] * s]);
    }
    return out;
  }
}
