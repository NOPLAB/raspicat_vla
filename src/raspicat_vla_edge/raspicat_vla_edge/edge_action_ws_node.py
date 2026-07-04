"""edge_action_ws_node — Web/スマホからの action chunk を受ける WebSocket ブリッジ。

web/ (raspicat-vla-web) の ``WsEdgeClient`` が送る JSON action chunk
(docs/design/web_port_spec.md の WS プロトコル。``proto/edge_action.proto`` の
``ActionChunk``/``ControlAck`` と意味的に同一で、values は fp16+base64) を受信し、
既存の ``trajectory_to_path`` で ``nav_msgs/Path`` に変換して
``/raspicat_vla/predicted_path`` へ流す。追従と安全停止は既存の
``path_follower_node`` がそのまま担う (空 Path = safe-stop)。

不変条件 (CLAUDE.md / mobile_port_spec §4 の踏襲):

- **ウォッチドッグ**: ``chunk_max_age_sec`` 以内に新しい chunk が来なければ
  空 Path を 1 回発行して follower を safe-stop させる。
- **受信スレッドから直接 publish しない**: websockets (asyncio) スレッドは
  最新 chunk をロック付きスロットへ置くだけで、publish は ROS タイマが行う。
  受信レートと publish レートを分離し、速すぎる送信側が ROS 側を詰まらせない
  (grpc_client.py の coalesce+pace の受け側に相当)。

LifecycleNode にはしない: ブリッジ自体は状態を持たず、安全機構は follower 側に
既にあるため。``websockets`` はサーバ起動時に遅延 import する (単体テストは
decode / ウォッチドッグを ws 依存なしで直接叩ける)。
"""
from __future__ import annotations

import base64
import json
import threading
import time
from typing import Optional, Tuple

import numpy as np
import rclpy
from nav_msgs.msg import Path
from rclpy.node import Node

from raspicat_vla_proto.conversions import fp16_bytes_to_float32_list

from .adapters._path_util import trajectory_to_path


def decode_chunk_msg(
    msg: dict,
    *,
    waypoint_spacing: float,
    frame_id: str = 'base_link',
) -> Tuple[Path, int, str]:
    """``action_chunk`` JSON dict -> (Path, 送信側 frame 連番, goal_id)。

    ``scaled_to_m`` が真なら x,y は既にメートル (spacing=1.0)、偽なら
    waypoint-spacing 単位なので ``waypoint_spacing`` を掛ける。
    malformed は ValueError (呼び出し側が ack にエラーを載せる)。
    """
    if msg.get('type') != 'action_chunk':
        raise ValueError(f"unexpected type: {msg.get('type')!r}")
    try:
        num_tokens = int(msg['num_tokens'])
        embed_dim = int(msg['embed_dim'])
        raw = base64.b64decode(msg['values_fp16_b64'], validate=True)
    except (KeyError, TypeError, ValueError) as e:  # binascii.Error は ValueError
        raise ValueError(f'malformed action_chunk: {e}') from e
    if num_tokens < 1 or embed_dim < 4:
        raise ValueError(f'bad shape: num_tokens={num_tokens} embed_dim={embed_dim}')

    values = fp16_bytes_to_float32_list(raw)
    if len(values) != num_tokens * embed_dim:
        raise ValueError(
            f'values length {len(values)} != num_tokens*embed_dim {num_tokens * embed_dim}'
        )
    waypoints = np.asarray(values, dtype=np.float32).reshape(num_tokens, embed_dim)
    spacing = 1.0 if msg.get('scaled_to_m') else waypoint_spacing
    path = trajectory_to_path(waypoints, spacing=spacing, frame_id=frame_id)
    return path, int(msg.get('frame_id', 0)), str(msg.get('goal_id', ''))


class EdgeActionWsNode(Node):
    """WebSocket server -> nav_msgs/Path bridge (ウォッチドッグ付き)。"""

    def __init__(self) -> None:
        super().__init__('edge_action_ws')
        self.declare_parameter('host', '0.0.0.0')
        self.declare_parameter('port', 8765)
        self.declare_parameter('path_topic', '/raspicat_vla/predicted_path')
        self.declare_parameter('frame_id', 'base_link')
        self.declare_parameter('chunk_max_age_sec', 1.0)
        # モデル出力 (spacing 単位) -> メートル。omnivla-edge の 0.1 m/unit。
        self.declare_parameter('waypoint_spacing', 0.1)
        self.declare_parameter('publish_rate_hz', 20.0)

        self._host: str = self.get_parameter('host').value
        self._port: int = self.get_parameter('port').value
        self._frame_id: str = self.get_parameter('frame_id').value
        self._max_age_sec: float = self.get_parameter('chunk_max_age_sec').value
        self._spacing: float = self.get_parameter('waypoint_spacing').value

        self._pub = self.create_publisher(
            Path, self.get_parameter('path_topic').value, 1)

        self._lock = threading.Lock()
        self._pending: Optional[Path] = None
        self._last_rx: Optional[float] = None  # time.monotonic()
        self._goal_id = ''
        self._stopped = True  # 最初の chunk まで「停止済み」扱い (空Path連打を防ぐ)

        rate = float(self.get_parameter('publish_rate_hz').value)
        self._timer = self.create_timer(1.0 / rate, self._on_timer)
        self._ws_thread: Optional[threading.Thread] = None

    # ------------------------------------------------------------ 受信 (wsスレッド)

    def handle_message(self, text: str, now: Optional[float] = None) -> dict:
        """1 メッセージを処理し ControlAck 相当の dict を返す。"""
        now = time.monotonic() if now is None else now
        try:
            msg = json.loads(text)
            if not isinstance(msg, dict):
                raise ValueError('not a JSON object')
            path, frame_seq, goal_id = decode_chunk_msg(
                msg, waypoint_spacing=self._spacing, frame_id=self._frame_id)
        except ValueError as e:
            self.get_logger().warning(f'bad chunk: {e}')
            with self._lock:
                following = not self._stopped
            return {'type': 'ack', 'frame_id': 0, 'following': following,
                    'status': f'error: {e}'}

        with self._lock:
            if goal_id != self._goal_id:
                self.get_logger().info(
                    f'goal changed: {self._goal_id!r} -> {goal_id!r}')
                self._goal_id = goal_id
            self._pending = path
            self._last_rx = now
            self._stopped = False
        return {'type': 'ack', 'frame_id': frame_seq, 'following': True,
                'status': 'ok'}

    # ------------------------------------------------------- publish (ROSタイマ)

    def _on_timer(self) -> None:
        self._tick(time.monotonic())

    def _tick(self, now: float) -> None:
        """最新 chunk の publish とウォッチドッグ。テストから直接叩ける。"""
        with self._lock:
            pending, self._pending = self._pending, None
            last_rx = self._last_rx
            stopped = self._stopped

        if pending is not None:
            pending.header.stamp = self.get_clock().now().to_msg()
            self._pub.publish(pending)
            return

        if last_rx is not None and not stopped and now - last_rx > self._max_age_sec:
            empty = Path()
            empty.header.frame_id = self._frame_id
            empty.header.stamp = self.get_clock().now().to_msg()
            self._pub.publish(empty)
            with self._lock:
                self._stopped = True
            self.get_logger().warning(
                f'no chunk for > {self._max_age_sec:.1f}s -> 空 Path で safe-stop')

    # ------------------------------------------------------------- WS server

    def start_server(self) -> None:
        """websockets サーバを daemon スレッドで起動する。"""
        self._ws_thread = threading.Thread(
            target=self._serve_forever, name='edge_action_ws', daemon=True)
        self._ws_thread.start()

    def _serve_forever(self) -> None:
        import asyncio

        try:
            # websockets >= 13 (新 asyncio 実装) / 9-12 (legacy) 両対応。
            try:
                from websockets.asyncio.server import serve  # type: ignore
            except ImportError:
                from websockets.server import serve  # type: ignore
        except ImportError:
            self.get_logger().error(
                'python3-websockets がありません。WS サーバは起動しません '
                '(pip install websockets)')
            return

        # v9 は handler(ws, path)、v14+ は handler(ws) で呼ぶ — 既定引数で両対応。
        async def handler(websocket, path=None):  # noqa: ANN001
            peer = getattr(websocket, 'remote_address', '?')
            self.get_logger().info(f'client connected: {peer}')
            try:
                async for text in websocket:
                    ack = self.handle_message(text)
                    await websocket.send(json.dumps(ack))
            except Exception as e:  # ConnectionClosed 含む — 切断は正常系
                self.get_logger().debug(f'client {peer} closed: {e}')
            finally:
                self.get_logger().info(f'client disconnected: {peer}')

        async def serve_main() -> None:
            async with serve(handler, self._host, self._port):
                self.get_logger().info(
                    f'EdgeActionService(WS) listening on ws://{self._host}:{self._port}')
                await asyncio.Future()  # 終了はプロセスごと (daemon thread)

        try:
            asyncio.run(serve_main())
        except Exception as e:
            self.get_logger().error(f'WS server died: {e}')


def main() -> None:
    rclpy.init()
    node = EdgeActionWsNode()
    node.start_server()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
