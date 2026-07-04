'use client';

/**
 * ゴール入力 (text / pose / image)。`app/lib/src/ui/goal_panel.dart` に相当。
 * image ゴールは現在フレームのスナップショットを使う (Flutter 版と同じ)。
 */

import { useRef, useState } from 'react';

import { imageGoal, poseGoal, textGoal, type Goal, type GoalMode } from '@/lib/goal';
import type { RgbaImage } from '@/lib/preprocessing';

export default function GoalPanel({
  onGoal,
  getCurrentFrame,
}: {
  onGoal: (goal: Goal) => void;
  getCurrentFrame: () => RgbaImage | null;
}) {
  const [tab, setTab] = useState<GoalMode>('text');
  const [text, setText] = useState('go to the door');
  const [x, setX] = useState('2.0');
  const [y, setY] = useState('0.0');
  const [theta, setTheta] = useState('0.0');
  const [note, setNote] = useState('');
  const previewRef = useRef<HTMLCanvasElement>(null);

  const submitText = () => {
    if (text.trim().length === 0) {
      setNote('テキストを入力してください');
      return;
    }
    setNote('');
    onGoal(textGoal(text.trim()));
  };

  const submitPose = () => {
    const px = Number(x);
    const py = Number(y);
    const pt = Number(theta);
    if (![px, py, pt].every(Number.isFinite)) {
      setNote('x / y / θ は数値で入力してください');
      return;
    }
    setNote('');
    onGoal(poseGoal(px, py, pt));
  };

  const submitImage = () => {
    const frame = getCurrentFrame();
    if (!frame) {
      setNote('まだフレームがありません (映像ソースを開始してください)');
      return;
    }
    // スナップショットを複製 (以後のフレーム更新の影響を受けない)。
    const copy: RgbaImage = {
      width: frame.width,
      height: frame.height,
      data: new Uint8ClampedArray(frame.data),
    };
    drawPreview(previewRef.current, copy);
    setNote('');
    onGoal(imageGoal(copy));
  };

  return (
    <div className="panel">
      <h2>ゴール</h2>
      <div className="tabs">
        {(['text', 'pose', 'image'] as const).map((mode) => (
          <button
            key={mode}
            className={tab === mode ? 'active' : ''}
            onClick={() => setTab(mode)}
          >
            {mode}
          </button>
        ))}
      </div>

      {tab === 'text' && (
        <div className="row">
          <input
            type="text"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && submitText()}
            placeholder="例: go to the door"
          />
          <button className="primary" onClick={submitText}>
            設定
          </button>
        </div>
      )}

      {tab === 'pose' && (
        <>
          <div className="row">
            <label>x[m]</label>
            <input type="number" step="0.1" value={x} onChange={(e) => setX(e.target.value)} />
            <label>y[m]</label>
            <input type="number" step="0.1" value={y} onChange={(e) => setY(e.target.value)} />
            <label>θ[rad]</label>
            <input
              type="number"
              step="0.1"
              value={theta}
              onChange={(e) => setTheta(e.target.value)}
            />
          </div>
          <div className="row">
            <button className="primary" onClick={submitPose}>
              設定
            </button>
            <span className="hint">ロボット相対 (x=前方, y=左)</span>
          </div>
        </>
      )}

      {tab === 'image' && (
        <>
          <div className="row">
            <button className="primary" onClick={submitImage}>
              現在フレームをゴールに設定
            </button>
          </div>
          <canvas ref={previewRef} className="goal-preview" width={96} height={96} />
        </>
      )}

      {note && <p className="hint">{note}</p>}
    </div>
  );
}

function drawPreview(canvas: HTMLCanvasElement | null, frame: RgbaImage) {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const img = new ImageData(
    frame.data instanceof Uint8ClampedArray
      ? new Uint8ClampedArray(frame.data)
      : Uint8ClampedArray.from(frame.data),
    frame.width,
    frame.height,
  );
  // 96×96 のプレビューへ縮小描画 (見た目用なので drawImage で十分)。
  const tmp = document.createElement('canvas');
  tmp.width = frame.width;
  tmp.height = frame.height;
  tmp.getContext('2d')?.putImageData(img, 0, 0);
  ctx.drawImage(tmp, 0, 0, canvas.width, canvas.height);
}
