"""Threaded gRPC bidi-stream client for VLA inference."""
from __future__ import annotations

import logging
import queue
import threading
from typing import Callable, Optional

import grpc

from raspicat_vla_proto import raspicat_vla_pb2, raspicat_vla_pb2_grpc


_LOG = logging.getLogger(__name__)

EmbeddingCallback = Callable[[raspicat_vla_pb2.ActionEmbedding], None]


class VLAClient:
    """Threaded bidirectional gRPC client.

    Two threads run between start() and stop():
      - sender: pulls Observation from the queue and yields them to gRPC
      - receiver: iterates the gRPC reply stream and calls on_embedding(...)

    On stream failure the client reconnects with exponential backoff up to
    `max_backoff_sec`. While disconnected, queued observations are dropped
    if the queue exceeds `queue_max`.

    Two mechanisms keep a slow remote from building an unbounded backlog —
    which would make the embeddings that come back lag the send counter by
    hundreds of frames and get rejected forever by the edge's embedding-cache
    floor (permanent WAITING_REMOTE / zero cmd_vel):

      - `latest_only` (default True): each send() coalesces the queue to a
        single pending observation; any older one still waiting is dropped.
      - `max_inflight` (default 1): the sender will not yield the next
        observation until that many replies are still outstanding, so the
        remote is never handed a backlog it can't drain. Because the wait
        happens *before* picking the observation to send, the freshest one
        available when the remote frees up is the one that goes out.

    Together these keep the returned frame_id within `max_inflight` round
    trips of the send counter, so the floor recovers normally and the action
    loop always works off a near-current embedding.
    """

    def __init__(
        self,
        *,
        address: str,
        on_embedding: EmbeddingCallback,
        queue_max: int = 32,
        latest_only: bool = True,
        max_inflight: int = 1,
        initial_backoff_sec: float = 0.5,
        max_backoff_sec: float = 5.0,
    ) -> None:
        if max_inflight < 1:
            raise ValueError('max_inflight must be >= 1')
        self._address = address
        self._on_embedding = on_embedding
        self._latest_only = latest_only
        self._max_inflight = max_inflight
        self._queue: 'queue.Queue[raspicat_vla_pb2.Observation]' = queue.Queue(maxsize=queue_max)
        # Permits to send: acquired before each yield, released on each reply.
        # Recreated per stream in _run_stream so reconnects start clean.
        self._inflight = threading.Semaphore(max_inflight)
        self._sentinel = object()
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._initial_backoff = initial_backoff_sec
        self._max_backoff = max_backoff_sec

    # ------------------------------------------------------------------ public

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run, name='VLAClient', daemon=True,
        )
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop_event.set()
        try:
            self._queue.put_nowait(self._sentinel)  # type: ignore[arg-type]
        except queue.Full:
            pass
        if self._thread is not None:
            self._thread.join(timeout=timeout)
            self._thread = None

    def send(self, obs: raspicat_vla_pb2.Observation) -> bool:
        if self._latest_only:
            # Coalesce to the newest observation: drain any stale one still
            # waiting so a slow remote can't build an unbounded backlog. The
            # individual queue ops are thread-safe; the drain+put isn't atomic
            # w.r.t. the sender thread, but that race is benign — worst case
            # the sender grabs our fresh obs a beat early or finds the queue
            # momentarily empty. We never accumulate, which is the invariant
            # that matters.
            while True:
                try:
                    stale = self._queue.get_nowait()
                except queue.Empty:
                    break
                if stale is self._sentinel:
                    # stop() was requested; put the sentinel back and bail.
                    try:
                        self._queue.put_nowait(self._sentinel)  # type: ignore[arg-type]
                    except queue.Full:
                        pass
                    return False
        try:
            self._queue.put_nowait(obs)
            return True
        except queue.Full:
            _LOG.warning('observation queue full; dropping frame_id=%s', obs.frame_id)
            return False

    # ------------------------------------------------------------------ internal

    def _run(self) -> None:
        backoff = self._initial_backoff
        while not self._stop_event.is_set():
            try:
                channel = grpc.insecure_channel(self._address)
                stub = raspicat_vla_pb2_grpc.VLAServiceStub(channel)
                _LOG.info('connecting to %s', self._address)
                self._run_stream(stub)
                channel.close()
                backoff = self._initial_backoff
            except grpc.RpcError as exc:
                _LOG.warning('gRPC error: %s; backing off %.2fs', exc, backoff)
                self._stop_event.wait(timeout=backoff)
                backoff = min(backoff * 2.0, self._max_backoff)
            except Exception as exc:  # noqa: BLE001
                _LOG.exception('unexpected client error: %s', exc)
                self._stop_event.wait(timeout=backoff)
                backoff = min(backoff * 2.0, self._max_backoff)

    def _request_iter(self):
        # Poll with short timeouts so a stop_event set while we're blocked
        # (waiting for an in-flight permit or for the queue to fill) still
        # wakes us up promptly instead of blocking forever.
        while not self._stop_event.is_set():
            # Wait for a send permit first: while we wait for the remote to
            # free up, fresh observations coalesce into the queue, so the one
            # we pick next is the freshest available.
            if not self._inflight.acquire(timeout=0.2):
                continue
            item = None
            while not self._stop_event.is_set():
                try:
                    item = self._queue.get(timeout=0.2)
                except queue.Empty:
                    continue
                break
            if item is None or item is self._sentinel:
                # Stopping: drop the permit we took and exit.
                self._inflight.release()
                return
            yield item

    def _run_stream(self, stub: raspicat_vla_pb2_grpc.VLAServiceStub) -> None:
        # Fresh permit budget for each (re)connection.
        self._inflight = threading.Semaphore(self._max_inflight)
        replies = stub.StreamInfer(self._request_iter())
        for reply in replies:
            # Reply in hand: free a send permit before invoking the callback
            # so the sender can prepare the next observation concurrently.
            self._inflight.release()
            try:
                self._on_embedding(reply)
            except Exception:  # noqa: BLE001
                _LOG.exception('on_embedding callback raised')
            if self._stop_event.is_set():
                return
