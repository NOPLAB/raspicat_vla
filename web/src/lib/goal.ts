/** ゴール指定 (text / pose / image)。`app/lib/src/goal.dart` の移植。 */

import { OmniVlaConfig } from './config';
import type { RgbaImage } from './preprocessing';

export type GoalMode = 'text' | 'pose' | 'image';

export interface Goal {
  readonly mode: GoalMode;
  readonly text: string;
  /** [x, y, theta]。x,y はロボット相対メートル (x=前方, y=左), theta は rad。 */
  readonly poseXyTheta: readonly [number, number, number] | null;
  readonly image: RgbaImage | null;
  /** ゴール識別用の安定キー。切替検知 (Pi 側ウォッチドッグ) とキャッシュに使う。 */
  readonly id: string;
}

export function modalityId(mode: GoalMode): number {
  switch (mode) {
    case 'text':
      return OmniVlaConfig.modalityText;
    case 'pose':
      return OmniVlaConfig.modalityPose;
    case 'image':
      return OmniVlaConfig.modalityImage;
  }
}

export function textGoal(text: string): Goal {
  return {
    mode: 'text',
    text,
    poseXyTheta: null,
    image: null,
    id: `text:${text}`,
  };
}

export function poseGoal(x: number, y: number, theta: number): Goal {
  const pose = [x, y, theta] as const;
  return {
    mode: 'pose',
    text: '',
    poseXyTheta: pose,
    image: null,
    id: `pose:${pose.map((v) => v.toFixed(3)).join(',')}`,
  };
}

let imageGoalSeq = 0;

export function imageGoal(image: RgbaImage): Goal {
  imageGoalSeq += 1;
  return {
    mode: 'image',
    text: '',
    poseXyTheta: null,
    image,
    id: `image:${imageGoalSeq}`,
  };
}
