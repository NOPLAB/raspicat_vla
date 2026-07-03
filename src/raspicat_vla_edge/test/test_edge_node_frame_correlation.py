"""Tests for pairing ActionEmbedding replies with the frame that produced them.

AsyncVLA's Edge_adapter compensates for cloud latency by comparing the
*current* camera frame against the frame the embedding was computed from
(run_asyncvla.py feeds shead(img_cur, img_past=VLA's frame, feature)). These
tests pin the edge_node plumbing: sent-frame bookkeeping, reply correlation,
and the action tick handing that frame to the adapter as ``past_image_rgb``.

No gRPC / no lifecycle: the node's internals are driven directly.
"""
import time

import numpy as np
import pytest
import rclpy
from nav_msgs.msg import Path

from raspicat_vla_edge.edge_node import VLAEdgeNode
from raspicat_vla_edge.embedding_cache import EmbeddingCache
from raspicat_vla_proto import raspicat_vla_pb2
from raspicat_vla_proto.conversions import float32_array_to_fp16_bytes


@pytest.fixture(scope='module')
def ros_runtime():
    rclpy.init()
    yield
    rclpy.shutdown()


@pytest.fixture()
def node(ros_runtime):
    n = VLAEdgeNode()
    n._cache = EmbeddingCache(max_age_sec=6.0, hard_timeout_sec=15.0)
    yield n
    n.destroy_node()


def _frame(fill: int) -> np.ndarray:
    return np.full((24, 32, 3), fill, dtype=np.uint8)


def _proto_embedding(frame_id: int) -> raspicat_vla_pb2.ActionEmbedding:
    values = np.zeros(8 * 4, dtype=np.float32)
    return raspicat_vla_pb2.ActionEmbedding(
        frame_id=frame_id,
        server_time_ns=time.monotonic_ns(),
        num_tokens=8,
        embed_dim=4,
        embedding_fp16=float32_array_to_fp16_bytes(values),
        inference_ms=1.0,
        model_version='test',
    )


def test_reply_pairs_embedding_with_sent_frame_and_prunes_older(node):
    node._sent_frames = {5: _frame(5), 6: _frame(6), 7: _frame(7)}

    node._on_embedding_received(_proto_embedding(6))

    cached = node._cache.get_latest_raw()
    assert cached is not None
    assert cached.obs_image_rgb is not None
    np.testing.assert_array_equal(cached.obs_image_rgb, _frame(6))
    # 5 can never be answered any more (server replies in order); 7 is still
    # in flight and must survive.
    assert list(node._sent_frames) == [7]


def test_reply_without_matching_frame_caches_none(node):
    node._sent_frames = {}
    node._on_embedding_received(_proto_embedding(3))
    cached = node._cache.get_latest_raw()
    assert cached is not None
    assert cached.obs_image_rgb is None


class _RecordingAdapter:
    """EdgeAdapter stand-in that records predict_path kwargs."""

    is_local = False

    def __init__(self):
        self.calls = []

    def predict_path(self, **kwargs):
        self.calls.append(kwargs)
        return Path()


class _StubPub:
    def __init__(self):
        self.published = []

    def publish(self, msg):
        self.published.append(msg)


def test_action_tick_passes_embedding_frame_as_past_image(node):
    adapter = _RecordingAdapter()
    node._adapter = adapter
    node._path_pub = _StubPub()
    node._latest_image = _frame(200)          # newest camera frame
    node._sent_frames = {1: _frame(10)}       # frame the cloud consumed
    node._on_embedding_received(_proto_embedding(1))

    node._action_tick()

    assert adapter.calls, 'adapter was not invoked'
    call = adapter.calls[-1]
    np.testing.assert_array_equal(call['cur_image_rgb'], _frame(200))
    np.testing.assert_array_equal(call['past_image_rgb'], _frame(10))


def test_action_tick_falls_back_to_cur_when_frame_uncorrelated(node):
    adapter = _RecordingAdapter()
    node._adapter = adapter
    node._path_pub = _StubPub()
    node._latest_image = _frame(200)
    node._sent_frames = {}
    node._on_embedding_received(_proto_embedding(1))

    node._action_tick()

    call = adapter.calls[-1]
    np.testing.assert_array_equal(call['past_image_rgb'], _frame(200))
