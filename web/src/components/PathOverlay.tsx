'use client';

/**
 * 予測 waypoint をプレビュー上にトップダウン投影で描く。
 * `app/lib/src/ui/path_painter.dart` の移植: 画面下端中央を原点に上=前進、
 * 60px/m。モノトーン: 実線+塗り点=実推論 / 破線+白抜き点=ダミー。
 */

import { useEffect, useRef } from 'react';

const METRES_TO_PIXELS = 60;

export default function PathOverlay({
  waypoints,
  fromModel,
}: {
  waypoints: Array<[number, number]>;
  fromModel: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const draw = () => {
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      if (w === 0 || h === 0) return;
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      const ctx = canvas.getContext('2d');
      if (!ctx) return;
      ctx.clearRect(0, 0, w, h);
      if (waypoints.length === 0) return;

      const originX = w / 2;
      const originY = h - 24;
      // x(前方)->上(-y), y(左)->左(-x)
      const project = ([px, py]: [number, number]): [number, number] => [
        originX - py * METRES_TO_PIXELS,
        originY - px * METRES_TO_PIXELS,
      ];

      ctx.strokeStyle = '#ffffff';
      ctx.fillStyle = '#ffffff';
      ctx.lineWidth = 3;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.setLineDash(fromModel ? [] : [8, 7]);
      ctx.beginPath();
      ctx.moveTo(originX, originY);
      for (const wp of waypoints) {
        const [x, y] = project(wp);
        ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.setLineDash([]);

      for (const wp of waypoints) {
        const [x, y] = project(wp);
        ctx.beginPath();
        ctx.arc(x, y, 4.5, 0, Math.PI * 2);
        if (fromModel) {
          ctx.fill();
        } else {
          // ダミーは白抜き。中を暗く塗って背景と分離する。
          ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
          ctx.fill();
          ctx.fillStyle = '#ffffff';
          ctx.lineWidth = 2;
          ctx.stroke();
        }
      }
      // ロボット原点: 十字マーカー。
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(originX, originY, 7, 0, Math.PI * 2);
      ctx.moveTo(originX - 12, originY);
      ctx.lineTo(originX + 12, originY);
      ctx.moveTo(originX, originY - 12);
      ctx.lineTo(originX, originY + 12);
      ctx.stroke();
    };

    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [waypoints, fromModel]);

  return <canvas ref={canvasRef} className="overlay" />;
}
