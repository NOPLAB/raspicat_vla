"""OmniVLAEdgeLocalAdapter — Plan 2B Path 2: run OmniVLA-edge ON the robot.

Unlike the cloud-heavy Path 1 (``adapters/omnivla.py``), this adapter runs the
full ``OmniVLA_edge`` policy + CLIP locally on the edge and turns the result into
a ``nav_msgs/Path`` directly — no cloud, no gRPC, no embedding cache. The edge
node runs in *standalone* mode (``is_local`` is True): the action loop drives
:meth:`predict_path` straight from the latest camera frame + goal.

The heavy lifting (model, CLIP, observation history, goal tensors) lives in the
ROS-free :class:`~raspicat_vla_edge.omnivla_edge_engine.OmniVLAEdgeEngine`, which
Path 3's Jetson backend (``raspicat_vla_remote.backends.omnivla_edge``) reuses.
This adapter is the thin ROS layer on top: hold the goal, call the engine, scale
the raw chunk to metres and build the Path.

Goal modalities supported in v1: ``text`` (language nav, modality 7), ``pose``
(modality 4) and ``image`` (modality 6). Single goal at a time (the proto carries
one ``GoalSpec``).

Limitations (v1):
- Requires CUDA (see the engine docstring — the OmniVLA_edge forward pass is
  GPU-only). ``device='cpu'`` is rejected.
- Without tf/odometry on the edge, a ``pose`` goal is interpreted as
  robot-relative metres (x forward, y left). Use ``text`` goals for the cleanest
  behaviour until edge localization is wired up.
"""
from __future__ import annotations

import threading
from typing import Optional, Tuple

import numpy as np
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Path

from .base import EdgeAdapter, EdgeGoal
# Re-export the ROS-free pipeline pieces from the shared engine so existing
# imports (and unit tests) that reach them here keep working.
from ..omnivla_edge_engine import (  # noqa: F401
    _METRIC_WAYPOINT_SPACING,
    _MODEL_PARAMS,
    OmniVLAEdgeEngine,
    _black_chw,
    _modality_id_for,
    _normalize_chw,
    _pose_goal_vector,
    _stack_frames,
)


def _trajectory_to_path(
    waypoints: np.ndarray,
    *,
    spacing: float = _METRIC_WAYPOINT_SPACING,
    frame_id: str = 'base_link',
) -> Path:
    """(T, 4) [x, y, cos, sin] in spacing units -> nav_msgs/Path (metres).

    x is forward, y is left (robot frame); orientation maps (cos, sin) to the
    (w, z) of a yaw-only quaternion. Pure numpy — no torch — so it is unit
    testable without model weights.
    """
    wp = np.asarray(waypoints, dtype=np.float32)
    if wp.ndim != 2 or wp.shape[-1] < 4:
        raise ValueError(
            f'expected (T, ACTION_DIM>=4) packed as (x, y, cos, sin); got shape={wp.shape}'
        )
    path = Path()
    path.header.frame_id = frame_id
    for x, y, c, s in wp[:, :4]:
        ps = PoseStamped()
        ps.header.frame_id = frame_id
        ps.pose.position.x = float(x) * spacing
        ps.pose.position.y = float(y) * spacing
        ps.pose.orientation.z = float(s)
        ps.pose.orientation.w = float(c)
        path.poses.append(ps)
    return path


class OmniVLAEdgeLocalAdapter(EdgeAdapter):
    """Runs the full OmniVLA-edge policy on the robot (Plan 2B Path 2)."""

    def __init__(
        self,
        *,
        weights_path: str = '/workspace/models/omnivla-edge/omnivla-edge.pth',
        clip_type: str = 'ViT-B/32',
        device: str = 'cuda:0',
    ) -> None:
        self._engine = OmniVLAEdgeEngine(
            weights_path=weights_path, clip_type=clip_type, device=device,
        )
        self._goal: Optional[EdgeGoal] = None
        self._lock = threading.Lock()

    @property
    def is_local(self) -> bool:
        # The whole policy runs here — the edge node needs no cloud.
        return True

    # -------------------------------------------------------------- goal intake

    def set_goal(self, goal: EdgeGoal) -> None:
        with self._lock:
            self._goal = goal

    # ------------------------------------------------------------- predict_path

    def predict_path(
        self,
        *,
        embedding: Optional[np.ndarray] = None,      # noqa: ARG002 (ignored: model runs on edge)
        embedding_shape: Optional[Tuple[int, int, int]] = None,  # noqa: ARG002
        cur_image_rgb: Optional[np.ndarray] = None,
        past_image_rgb: Optional[np.ndarray] = None,  # noqa: ARG002 (history kept internally)
        frame_id: str = 'base_link',
    ) -> Path:
        if cur_image_rgb is None:
            raise ValueError('OmniVLAEdgeLocalAdapter requires cur_image_rgb')

        with self._lock:
            goal = self._goal
        if goal is None:
            # No goal yet -> empty Path (the follower safe-stops). Don't pollute
            # the ring buffer until we actually have a goal to chase.
            path = Path()
            path.header.frame_id = frame_id
            return path

        waypoints = self._engine.infer_chunk(
            cur_image_rgb=cur_image_rgb,
            goal_mode=goal.mode,
            goal_text=goal.text,
            goal_pose_xy_theta=goal.pose_xy_theta,
            goal_image_rgb=goal.image_rgb,
        )
        return _trajectory_to_path(
            waypoints, spacing=self._engine.metric_waypoint_spacing, frame_id=frame_id,
        )
