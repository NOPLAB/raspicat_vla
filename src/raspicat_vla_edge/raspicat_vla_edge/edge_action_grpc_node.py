"""edge_action_grpc_node — スマホ (Flutter app) からの action chunk を受ける gRPC サーバ。

``proto/edge_action.proto`` の ``EdgeActionService.StreamActions`` の Pi 側実装
(mobile_port_spec.md §4 Phase 4)。app/ の ``GrpcEdgeClient`` が stream 送信する
``ActionChunk`` (fp16) を受信し、既存の ``trajectory_to_path`` で
``nav_msgs/Path`` に変換して ``/raspicat_vla/predicted_path`` へ流す。追従と
安全停止は既存の ``path_follower_node`` がそのまま担う (空 Path = safe-stop)。

``edge_action_ws_node.py`` (Web 版ブリッジ) の gRPC 双子。トランスポートと
メッセージ形式 (protobuf vs JSON+base64) 以外は同じ設計を保つ:

- **ウォッチドッグ**: ``chunk_max_age_sec`` 以内に新しい chunk が来なければ
  空 Path を 1 回発行して follower を safe-stop させる。
- **受信スレッドから直接 publish しない**: gRPC servicer スレッドは最新 chunk
  をロック付きスロットへ置くだけで、publish は ROS タイマが行う
  (grpc_client.py の coalesce+pace の受け側に相当)。

LifecycleNode にはしない: ブリッジ自体は状態を持たず、安全機構は follower 側に
既にあるため。``grpc`` はサーバ起動時に遅延 import する (単体テストは
decode / ウォッチドッグを grpc 依存なしで直接叩ける)。
"""
from __future__ import annotations

import threading
import time
from concurrent import futures
from typing import Optional, Tuple

import numpy as np
import rclpy
from nav_msgs.msg import Path
from rclpy.node import Node

from raspicat_vla_proto import edge_action_pb2
from raspicat_vla_proto.conversions import fp16_bytes_to_float32_list

from .adapters._path_util import trajectory_to_path


def decode_action_chunk(
    chunk: edge_action_pb2.ActionChunk,
    *,
    waypoint_spacing: float,
    frame_id: str = 'base_link',
) -> Tuple[Path, int, str]:
    """proto ``ActionChunk`` -> (Path, 送信側 frame 連番, goal_id)。

    ``scaled_to_m`` が真なら x,y は既にメートル (spacing=1.0)、偽なら
    waypoint-spacing 単位なので ``waypoint_spacing`` を掛ける。
    malformed は ValueError (呼び出し側が ack にエラーを載せる)。
    """
    num_tokens = int(chunk.num_tokens)
    embed_dim = int(chunk.embed_dim)
    if num_tokens < 1 or embed_dim < 4:
        raise ValueError(f'bad shape: num_tokens={num_tokens} embed_dim={embed_dim}')

    values = fp16_bytes_to_float32_list(chunk.values_fp16)
    if len(values) != num_tokens * embed_dim:
        raise ValueError(
            f'values length {len(values)} != num_tokens*embed_dim {num_tokens * embed_dim}'
        )
    waypoints = np.asarray(values, dtype=np.float32).reshape(num_tokens, embed_dim)
    spacing = 1.0 if chunk.scaled_to_m else waypoint_spacing
    path = trajectory_to_path(waypoints, spacing=spacing, frame_id=frame_id)
    return path, int(chunk.frame_id), str(chunk.goal_id)


class EdgeActionGrpcNode(Node):
    """gRPC server -> nav_msgs/Path bridge (ウォッチドッグ付き)。"""

    def __init__(self) -> None:
        super().__init__('edge_action_grpc')
        self.declare_parameter('host', '0.0.0.0')
        self.declare_parameter('port', 50061)
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
        self._grpc_server = None

    # --------------------------------------------------- 受信 (grpcスレッド)

    def handle_chunk(
        self,
        chunk: edge_action_pb2.ActionChunk,
        now: Optional[float] = None,
    ) -> edge_action_pb2.ControlAck:
        """1 chunk を処理し ControlAck を返す。"""
        now = time.monotonic() if now is None else now
        try:
            path, frame_seq, goal_id = decode_action_chunk(
                chunk, waypoint_spacing=self._spacing, frame_id=self._frame_id)
        except ValueError as e:
            self.get_logger().warning(f'bad chunk: {e}')
            with self._lock:
                following = not self._stopped
            return edge_action_pb2.ControlAck(
                frame_id=int(chunk.frame_id), following=following,
                status=f'error: {e}')

        with self._lock:
            if goal_id != self._goal_id:
                self.get_logger().info(
                    f'goal changed: {self._goal_id!r} -> {goal_id!r}')
                self._goal_id = goal_id
            self._pending = path
            self._last_rx = now
            self._stopped = False
        # from_model=false (アプリに ONNX 未配置、ダミー軌道) もそのまま追従する。
        # cmd_vel preview (非モータートピック) での配管確認が主用途のため。実モーター
        # 運用 (--drive-motors) では ack の status で送信側に見えるようにしておく。
        status = 'ok' if chunk.from_model else 'ok-dummy'
        return edge_action_pb2.ControlAck(
            frame_id=frame_seq, following=True, status=status)

    # ------------------------------------------------- publish (ROSタイマ)

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

    # ------------------------------------------------------------- gRPC server

    def start_server(self) -> None:
        """gRPC サーバを起動する (grpc が自前のスレッドプールで受ける)。"""
        import grpc

        from raspicat_vla_proto import edge_action_pb2_grpc

        node = self

        class _Servicer(edge_action_pb2_grpc.EdgeActionServiceServicer):
            def StreamActions(self, request_iterator, context):  # noqa: N802
                peer = context.peer()
                node.get_logger().info(f'client connected: {peer}')
                try:
                    for chunk in request_iterator:
                        yield node.handle_chunk(chunk)
                finally:
                    node.get_logger().info(f'client disconnected: {peer}')

        server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
        edge_action_pb2_grpc.add_EdgeActionServiceServicer_to_server(
            _Servicer(), server)
        server.add_insecure_port(f'{self._host}:{self._port}')
        server.start()
        self._grpc_server = server
        self.get_logger().info(
            f'EdgeActionService(gRPC) listening on {self._host}:{self._port}')

    def stop_server(self) -> None:
        if self._grpc_server is not None:
            self._grpc_server.stop(grace=1.0)
            self._grpc_server = None


def main() -> None:
    rclpy.init()
    node = EdgeActionGrpcNode()
    node.start_server()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.stop_server()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
