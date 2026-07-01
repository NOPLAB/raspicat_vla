"""Unit tests for path_follower_node's hold-last-command smoothing.

Drives ``_decide_cmd`` directly with synthetic timestamps so the stop-go
smoothing is exercised deterministically, without a running executor or the
20 Hz wall-clock timer.
"""
import pytest
import rclpy
from rclpy.time import Time
from nav_msgs.msg import Path
from geometry_msgs.msg import PoseStamped

from raspicat_vla_edge.path_follower_node import PathFollowerNode


@pytest.fixture(scope='module')
def ros_runtime():
    rclpy.init()
    yield
    rclpy.shutdown()


def _forward_path(n: int = 10, step: float = 0.1, frame: str = 'base_link') -> Path:
    path = Path()
    path.header.frame_id = frame
    for i in range(1, n + 1):
        ps = PoseStamped()
        ps.pose.position.x = i * step
        path.poses.append(ps)
    return path


def _empty_path(frame: str = 'base_link') -> Path:
    path = Path()
    path.header.frame_id = frame
    return path


def _t(sec: float) -> Time:
    return Time(nanoseconds=int(sec * 1e9))


def _make_node(hold_timeout_sec: float = 1.0) -> PathFollowerNode:
    node = PathFollowerNode()
    node._hold_timeout_ns = int(hold_timeout_sec * 1e9)
    return node


def test_holds_last_command_across_empty_path(ros_runtime):
    node = _make_node(hold_timeout_sec=1.0)
    try:
        # Moving forward.
        node._on_path(_forward_path())
        cmd = node._decide_cmd(_t(0.0))
        assert cmd.linear > 0.0

        # Empty path arrives 0.5 s later: within the hold window -> keep moving.
        node._on_path(_empty_path())
        held = node._decide_cmd(_t(0.5))
        assert held.linear == pytest.approx(cmd.linear)

        # Still empty at 1.5 s: past the 1.0 s hold window -> safe-stop.
        stopped = node._decide_cmd(_t(1.5))
        assert stopped.linear == 0.0 and stopped.angular == 0.0
    finally:
        node.destroy_node()


def test_hold_window_resets_on_new_motion(ros_runtime):
    node = _make_node(hold_timeout_sec=1.0)
    try:
        node._on_path(_forward_path())
        node._decide_cmd(_t(0.0))

        node._on_path(_empty_path())
        node._decide_cmd(_t(0.8))  # still holding

        # New moving path refreshes the latch...
        node._on_path(_forward_path())
        node._decide_cmd(_t(0.9))

        # ...so an empty path at 1.5 s is only 0.6 s past the refresh -> hold.
        node._on_path(_empty_path())
        held = node._decide_cmd(_t(1.5))
        assert held.linear > 0.0
    finally:
        node.destroy_node()


def test_frame_mismatch_stops_immediately(ros_runtime):
    node = _make_node(hold_timeout_sec=5.0)
    try:
        node._on_path(_forward_path())
        moving = node._decide_cmd(_t(0.0))
        assert moving.linear > 0.0

        # A wrong-frame path is a correctness fault: stop now, don't coast even
        # though we're well within the hold window.
        node._on_path(_forward_path(frame='map'))
        stopped = node._decide_cmd(_t(0.1))
        assert stopped.linear == 0.0 and stopped.angular == 0.0
    finally:
        node.destroy_node()


def test_hold_disabled_emits_zero_immediately(ros_runtime):
    node = _make_node(hold_timeout_sec=0.0)
    try:
        node._on_path(_forward_path())
        node._decide_cmd(_t(0.0))

        node._on_path(_empty_path())
        stopped = node._decide_cmd(_t(0.01))
        assert stopped.linear == 0.0 and stopped.angular == 0.0
    finally:
        node.destroy_node()
