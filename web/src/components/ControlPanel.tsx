'use client';

/** 映像ソース選択・Pi (WebSocket) 接続・モデルキャッシュ管理。 */

import { useRef } from 'react';

export type VideoSource = 'camera' | 'file';

export default function ControlPanel({
  source,
  onSource,
  onFile,
  wsUrl,
  onWsUrl,
  wsConnected,
  onWsConnect,
  onWsDisconnect,
  running,
  onToggleRunning,
  onClearCache,
  cacheNote,
}: {
  source: VideoSource;
  onSource: (s: VideoSource) => void;
  onFile: (file: File) => void;
  wsUrl: string;
  onWsUrl: (url: string) => void;
  wsConnected: boolean;
  onWsConnect: () => void;
  onWsDisconnect: () => void;
  running: boolean;
  onToggleRunning: () => void;
  onClearCache: () => void;
  cacheNote: string;
}) {
  const fileRef = useRef<HTMLInputElement>(null);

  return (
    <div className="panel">
      <h2>入力と接続</h2>

      <div className="row">
        <span className="row-label">映像:</span>
        <button
          type="button"
          className={source === 'camera' ? 'primary' : ''}
          onClick={() => onSource('camera')}
        >
          カメラ
        </button>
        <button type="button" onClick={() => fileRef.current?.click()}>
          動画ファイル{source === 'file' ? ' ✓' : ''}
        </button>
        <input
          ref={fileRef}
          type="file"
          accept="video/*"
          style={{ display: 'none' }}
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) onFile(f);
            e.target.value = '';
          }}
        />
        <button type="button" onClick={onToggleRunning}>
          {running ? '⏸ 停止' : '▶ 再開'}
        </button>
      </div>

      <div className="row">
        <label htmlFor="ws-url">Pi WS:</label>
        <input
          id="ws-url"
          type="text"
          value={wsUrl}
          onChange={(e) => onWsUrl(e.target.value)}
          placeholder="ws://raspicat.local:8765"
          disabled={wsConnected}
        />
        {wsConnected ? (
          <button type="button" onClick={onWsDisconnect}>
            切断
          </button>
        ) : (
          <button
            type="button"
            className="primary"
            onClick={onWsConnect}
            disabled={wsUrl.trim() === ''}
          >
            接続
          </button>
        )}
      </div>
      <p className="hint">
        未接続の間はブラウザ内ログのみ (LoggingEdgeClient 相当)。https
        配信ページからは ws:// が塞がれるため、localhost 配信で使うこと。
      </p>

      <div className="row">
        <button type="button" onClick={onClearCache}>
          モデルキャッシュ削除 (~590MB)
        </button>
        {cacheNote && <span className="hint">{cacheNote}</span>}
      </div>
    </div>
  );
}
