"""ROS2 wrapper around PurePursuit: subscribe to Path, publish Twist."""
from __future__ import annotations

from typing import List, Optional

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Path
from rclpy.node import Node

from .pure_pursuit import PurePursuit, Pose2D, TwistCmd, Waypoint


class PathFollowerNode(Node):

    def __init__(self) -> None:
        super().__init__('path_follower_node')
        self.declare_parameter('lookahead', 0.4)
        self.declare_parameter('max_v', 0.4)
        self.declare_parameter('max_w', 1.0)
        self.declare_parameter('rate_hz', 20.0)
        self.declare_parameter('path_topic', '/raspicat_vla/predicted_path')
        self.declare_parameter('cmd_vel_topic', '/cmd_vel')
        # Plan 1: paths are always treated as being expressed in the robot
        # frame (typically base_link). If a path arrives with a different
        # frame_id we warn and zero the command, since blindly following
        # would steer toward the wrong pose.
        self.declare_parameter('expected_frame', 'base_link')
        # Hold-last-command: paths (hence cmd_vel) only change at the inference
        # rate (~2 Hz), and some inferences yield a zero command (empty path on
        # WAITING/STALE, or a pure-pursuit stop), so the raw command stutters
        # stop-go between inferences. To keep motion continuous we *latch* the
        # last moving command and keep republishing it when the freshly computed
        # command is zero, up to hold_timeout_sec. Past that (a genuine stall /
        # loss of updates) we safe-stop. Set to 0 to disable (revert to
        # "zero command is emitted immediately").
        self.declare_parameter('hold_timeout_sec', 1.0)
        # A command is "moving" (worth latching) if |linear| or |angular|
        # exceeds this. Below it we treat the command as a stop.
        self.declare_parameter('cmd_epsilon', 1e-3)

        self._pp = PurePursuit(
            lookahead=float(self.get_parameter('lookahead').value),
            max_v=float(self.get_parameter('max_v').value),
            max_w=float(self.get_parameter('max_w').value),
            no_backward=True,
        )
        self._expected_frame: str = str(self.get_parameter('expected_frame').value)
        self._hold_timeout_ns: int = int(
            float(self.get_parameter('hold_timeout_sec').value) * 1e9)
        self._cmd_eps: float = float(self.get_parameter('cmd_epsilon').value)
        self._latest: List[Waypoint] = []
        self._frame_mismatch: bool = False
        # Last "moving" command and the time it was computed, for hold-last.
        self._held_cmd: Optional[TwistCmd] = None
        self._held_at = None  # rclpy Time or None
        self._sub = self.create_subscription(
            Path,
            self.get_parameter('path_topic').value,
            self._on_path, 10,
        )
        self._pub = self.create_publisher(
            Twist, self.get_parameter('cmd_vel_topic').value, 10,
        )
        rate = float(self.get_parameter('rate_hz').value)
        self._timer = self.create_timer(1.0 / rate, self._tick)

    def _on_path(self, msg: Path) -> None:
        if msg.header.frame_id and msg.header.frame_id != self._expected_frame:
            if not self._frame_mismatch:
                self.get_logger().warn(
                    f'path frame_id={msg.header.frame_id!r} != '
                    f'expected {self._expected_frame!r}; zeroing cmd_vel'
                )
            self._frame_mismatch = True
            self._latest = []
            return
        self._frame_mismatch = False
        wps: List[Waypoint] = []
        for ps in msg.poses:
            wps.append(Waypoint(x=ps.pose.position.x, y=ps.pose.position.y))
        self._latest = wps

    def _tick(self) -> None:
        cmd = self._decide_cmd(self.get_clock().now())
        twist = Twist()
        twist.linear.x = float(cmd.linear)
        twist.angular.z = float(cmd.angular)
        self._pub.publish(twist)

    def _decide_cmd(self, now) -> TwistCmd:
        """Pick the command to publish, applying hold-last-command.

        Pure w.r.t. ROS I/O (takes ``now``, mutates only the latch state) so the
        stop-go smoothing is unit-testable without a running executor.
        """
        cmd = self._pp.compute(robot=Pose2D(0.0, 0.0, 0.0), path=self._latest)

        # A frame mismatch is a correctness fault, not a transient gap: stop
        # immediately and drop any held command (don't coast on a bad target).
        if self._frame_mismatch:
            self._held_cmd = None
            self._held_at = None
            return cmd

        if abs(cmd.linear) > self._cmd_eps or abs(cmd.angular) > self._cmd_eps:
            # Fresh moving command: use it and latch it for the hold window.
            self._held_cmd = cmd
            self._held_at = now
            return cmd

        # Freshly computed command is zero (empty path / pure-pursuit stop). If
        # we're still within the hold window, maintain the last moving command
        # so motion doesn't stutter between inferences; otherwise safe-stop.
        if (
            self._hold_timeout_ns > 0
            and self._held_cmd is not None
            and self._held_at is not None
            and (now - self._held_at).nanoseconds <= self._hold_timeout_ns
        ):
            return self._held_cmd

        self._held_cmd = None
        self._held_at = None
        return cmd


def main() -> None:
    rclpy.init()
    node = PathFollowerNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()
