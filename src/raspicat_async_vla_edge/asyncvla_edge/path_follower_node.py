"""ROS2 wrapper around PurePursuit: subscribe to Path, publish Twist."""
from __future__ import annotations

from typing import List

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Path
from rclpy.node import Node

from .pure_pursuit import PurePursuit, Pose2D, Waypoint


class PathFollowerNode(Node):

    def __init__(self) -> None:
        super().__init__('path_follower_node')
        self.declare_parameter('lookahead', 0.4)
        self.declare_parameter('max_v', 0.4)
        self.declare_parameter('max_w', 1.0)
        self.declare_parameter('rate_hz', 20.0)
        self.declare_parameter('path_topic', '/asyncvla/predicted_path')
        self.declare_parameter('cmd_vel_topic', '/cmd_vel')
        # Plan 1: paths are always treated as being expressed in the robot
        # frame (typically base_link). If a path arrives with a different
        # frame_id we warn and zero the command, since blindly following
        # would steer toward the wrong pose.
        self.declare_parameter('expected_frame', 'base_link')

        self._pp = PurePursuit(
            lookahead=float(self.get_parameter('lookahead').value),
            max_v=float(self.get_parameter('max_v').value),
            max_w=float(self.get_parameter('max_w').value),
            no_backward=True,
        )
        self._expected_frame: str = str(self.get_parameter('expected_frame').value)
        self._latest: List[Waypoint] = []
        self._frame_mismatch: bool = False
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
        cmd = self._pp.compute(robot=Pose2D(0.0, 0.0, 0.0), path=self._latest)
        twist = Twist()
        twist.linear.x = float(cmd.linear)
        twist.angular.z = float(cmd.angular)
        self._pub.publish(twist)


def main() -> None:
    rclpy.init()
    node = PathFollowerNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()
