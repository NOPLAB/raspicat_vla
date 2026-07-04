'use client';

/**
 * 予測 waypoint をプレビュー上にトップダウン投影で描く。
 * `app/lib/src/ui/path_painter.dart` の移植: 画面下端中央を原点に上=前進、
 * 60px/m、緑=実推論 / 琥珀=ダミー。
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

      const color = fromModel ? '#3dfc9a' : '#ffc24b';
      ctx.strokeStyle = color;
      ctx.lineWidth = 4;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(originX, originY);
      for (const wp of waypoints) {
        const [x, y] = project(wp);
        ctx.lineTo(x, y);
      }
      ctx.stroke();

      ctx.fillStyle = color;
      for (const wp of waypoints) {
        const [x, y] = project(wp);
        ctx.beginPath();
        ctx.arc(x, y, 5, 0, Math.PI * 2);
        ctx.fill();
      }
      // ロボット原点。
      ctx.fillStyle = '#ffffff';
      ctx.beginPath();
      ctx.arc(originX, originY, 6, 0, Math.PI * 2);
      ctx.fill();
    };

    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [waypoints, fromModel]);

  return <canvas ref={canvasRef} className="overlay" />;
}
