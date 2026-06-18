"""Tests for the VLA gRPC bidi-stream client wrapper.

The client must:
  - send observations from a thread-safe input
  - deliver embeddings via a callback
  - be startable / stoppable cleanly
  - tolerate the server going away (reconnect attempt)
"""
import threading
import time

import pytest

from raspicat_vla_remote.dummy_server import DummyServer
from raspicat_vla_edge.grpc_client import VLAClient
from raspicat_vla_proto import raspicat_vla_pb2


@pytest.fixture
def server():
    s = DummyServer(host='localhost', port=0, num_tokens=4, embed_dim=8, inference_ms=1.0)
    port = s.start()
    yield port
    s.stop(grace_sec=0.5)


def _make_obs(frame_id: int) -> raspicat_vla_pb2.Observation:
    return raspicat_vla_pb2.Observation(
        frame_id=frame_id,
        capture_time_ns=time.monotonic_ns(),
        image_jpeg=b'\xff\xd8\xff' + b'\x00' * 16,
        image_width=224,
        image_height=224,
        goal=raspicat_vla_pb2.GoalSpec(
            mode=raspicat_vla_pb2.GoalSpec.POSE,
            pose=raspicat_vla_pb2.Pose2D(x=0.0, y=0.0, theta=0.0),
            frame_id='base_link',
        ),
    )


def test_client_round_trips_via_dummy_server(server):
    """A paced caller (one obs per reply) gets every frame back, in order."""
    received = []
    cond = threading.Condition()

    def on_emb(emb):
        with cond:
            received.append(emb)
            cond.notify_all()

    client = VLAClient(address=f'localhost:{server}', on_embedding=on_emb)
    client.start()
    try:
        for i in range(5):
            client.send(_make_obs(i))
            with cond:
                cond.wait_for(lambda i=i: len(received) >= i + 1, timeout=5.0)
        assert [r.frame_id for r in received] == [0, 1, 2, 3, 4]
    finally:
        client.stop()


def test_client_coalesces_when_caller_outpaces_remote(server):
    """When sends pile up faster than the remote drains, intermediate
    observations are dropped (latest_only + max_inflight) but the most recent
    frame is always eventually delivered — so the returned frame_id can't lag
    the send counter without bound (the bug that stalled the sim)."""
    received = []
    cond = threading.Condition()

    def on_emb(emb):
        with cond:
            received.append(emb)
            cond.notify_all()

    client = VLAClient(address=f'localhost:{server}', on_embedding=on_emb)
    client.start()
    try:
        last = 199
        for i in range(last + 1):
            client.send(_make_obs(i))
        with cond:
            cond.wait_for(lambda: received and received[-1].frame_id == last, timeout=5.0)
        ids = [r.frame_id for r in received]
        assert ids[-1] == last                 # latest always wins
        assert len(ids) < last + 1             # intermediates coalesced away
        assert ids == sorted(ids)              # delivered in order, never backwards
    finally:
        client.stop()
