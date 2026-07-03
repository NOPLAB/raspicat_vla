"""Tests for the edge node's in-process camera capture (camera_device param).

No real V4L2 device in CI: the open-failure path and the capture-loop
bookkeeping are tested; the happy-path open is exercised on the robot.
"""
import numpy as np
import pytest
import rclpy
from rclpy.lifecycle import TransitionCallbackReturn

from raspicat_vla_edge.edge_node import VLAEdgeNode


@pytest.fixture(scope='module')
def ros_runtime():
    rclpy.init()
    yield
    rclpy.shutdown()


@pytest.fixture()
def node(ros_runtime):
    n = VLAEdgeNode()
    yield n
    n.destroy_node()


def test_configure_fails_when_camera_device_cannot_be_opened(node):
    node.set_parameters([
        rclpy.parameter.Parameter('camera_device', value='/dev/nonexistent-video99'),
    ])
    assert node.on_configure(None) == TransitionCallbackReturn.FAILURE
    assert node._camera_cap is None
    assert node._image_sub is None  # no fallback subscription in camera mode


def test_configure_without_camera_device_subscribes_to_image_topic(node):
    assert node.on_configure(None) == TransitionCallbackReturn.SUCCESS
    assert node._camera_cap is None
    assert node._image_sub is not None
    node.on_cleanup(None)


class _StubCap:
    """VideoCapture stand-in: yields one BGR frame, then stops the loop."""

    def __init__(self, node):
        self._node = node

    def read(self):
        self._node._camera_stop.set()  # exit after this frame
        frame_bgr = np.zeros((4, 4, 3), dtype=np.uint8)
        frame_bgr[..., 0] = 255  # blue plane in BGR
        return True, frame_bgr

    def release(self):
        pass


def test_camera_loop_stores_rgb_frame_and_stamp(node):
    node._camera_cap = _StubCap(node)
    node._camera_stop.clear()

    node._camera_loop()

    assert node._latest_image is not None
    # BGR blue must land in the RGB blue channel (i.e. cvtColor happened).
    assert node._latest_image[0, 0, 2] == 255
    assert node._latest_image[0, 0, 0] == 0
    assert node._latest_image_stamp_ns > 0
