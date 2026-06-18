"""OmniVLAEdgeLocalAdapter — Plan 2B Path 2: run OmniVLA-edge ON the robot.

Unlike the cloud-heavy Path 1 (``adapters/omnivla.py``), this adapter loads the
full ``OmniVLA_edge`` policy (EfficientNet-b0 encoders + FiLM + a transformer
decoder) plus CLIP ViT-B/32 locally and runs the whole forward pass on the edge.
The cloud only needs to emit *some* embedding to keep the edge's
``EmbeddingCache`` fresh (a ``dummy`` backend works as the heartbeat) — its
payload is ignored here.

Pipeline per ``predict_path`` (mirrors
``external/OmniVLA/inference/run_omnivla_edge.py``):

1. Push the current RGB frame into a ``context_size+1`` ring buffer; build
   ``obs_images`` (1, 3*(context_size+1), 96, 96) ImageNet-normalized.
2. From the latest goal (``set_goal``), derive ``modality_id`` and build the
   goal tensors: ``goal_pose`` (1, 4), ``goal_image`` (1, 3, 96, 96), CLIP text
   features (1, 512), and the zero-fill satellite ``map_images`` (1, 9, 96, 96).
3. Forward through ``OmniVLA_edge`` -> action chunk (1, len_traj_pred, 4) in the
   robot frame, packed as ``(x_fwd, y_left, cos, sin)`` in waypoint-spacing units.
4. Scale x/y by ``metric_waypoint_spacing`` and build a ``nav_msgs/Path``.

Goal modalities supported in v1: ``text`` (language nav, modality 7), ``pose``
(modality 4) and ``image`` (modality 6). Single goal at a time (the proto carries
one ``GoalSpec``).

Limitations (v1):
- The upstream ``OmniVLA_edge.forward`` calls ``obs_img.get_device()`` and feeds
  the result to ``.to(device)``, which is GPU-only (CPU tensors report device
  ``-1``). So this adapter requires CUDA; ``device='cpu'`` is rejected.
- Without tf/odometry on the edge, a ``pose`` goal is interpreted as
  robot-relative metres (x forward, y left). Use ``text`` goals for the cleanest
  behaviour until edge localization is wired up.
"""
from __future__ import annotations

import logging
import math
import os
import threading
from typing import List, Optional, Tuple

import cv2
import numpy as np
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Path

from .base import EdgeAdapter, EdgeGoal


_LOG = logging.getLogger(__name__)

_IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
_IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# Trajectory waypoints come out of the model in units of this spacing (metres);
# matches metric_waypoint_spacing in run_omnivla_edge.py.
_METRIC_WAYPOINT_SPACING = 0.1
# Clamp pose-goal range like run_omnivla_edge.py (thres_dist).
_GOAL_DIST_THRESHOLD_M = 30.0

# Modality ids from run_omnivla_edge.run_forward_pass. We only expose the
# single-goal subset reachable from the proto GoalSpec.
_MODALITY_POSE = 4      # pose only
_MODALITY_IMAGE = 6     # image only
_MODALITY_TEXT = 7      # language only
_MODALITY_TEXT_POSE = 8  # language + pose (unused in v1; here for completeness)


def _normalize_chw(image_rgb: np.ndarray, size: int) -> np.ndarray:
    """RGB uint8 HxWx3 -> (3, size, size) ImageNet-normalized float32 (CHW)."""
    if image_rgb.dtype != np.uint8 or image_rgb.ndim != 3 or image_rgb.shape[2] != 3:
        raise ValueError(
            f'expected uint8 HxWx3 RGB, got dtype={image_rgb.dtype} shape={image_rgb.shape}'
        )
    img = cv2.resize(image_rgb, (size, size), interpolation=cv2.INTER_AREA)
    arr = img.astype(np.float32) / 255.0
    arr = (arr - _IMAGENET_MEAN) / _IMAGENET_STD
    return np.transpose(arr, (2, 0, 1))


def _black_chw(size: int) -> np.ndarray:
    """ImageNet-normalized all-black (3, size, size) — the zero-fill satellite/goal."""
    return _normalize_chw(np.zeros((size, size, 3), dtype=np.uint8), size)


def _modality_id_for(mode: str) -> int:
    """Map a proto goal mode string to an OmniVLA-edge modality id."""
    if mode == 'text':
        return _MODALITY_TEXT
    if mode == 'pose':
        return _MODALITY_POSE
    if mode == 'image':
        return _MODALITY_IMAGE
    raise ValueError(f"unknown goal mode {mode!r} (expected 'text'|'pose'|'image')")


def _pose_goal_vector(pose_xy_theta: Tuple[float, float, float]) -> np.ndarray:
    """Build the (4,) goal_pose vector from a robot-relative pose goal.

    Mirrors run_omnivla_edge.py: the model consumes
    ``(rel_y/spacing, -rel_x/spacing, cos(dtheta), sin(dtheta))`` where rel_x is
    forward and rel_y is left, with the range clamped to thres_dist. We assume
    the goal x/y are already robot-relative metres (no edge tf in v1).
    """
    rel_x, rel_y, theta = float(pose_xy_theta[0]), float(pose_xy_theta[1]), float(pose_xy_theta[2])
    radius = math.hypot(rel_x, rel_y)
    if radius > _GOAL_DIST_THRESHOLD_M:
        scale = _GOAL_DIST_THRESHOLD_M / radius
        rel_x *= scale
        rel_y *= scale
    return np.array(
        [
            rel_y / _METRIC_WAYPOINT_SPACING,
            -rel_x / _METRIC_WAYPOINT_SPACING,
            math.cos(theta),
            math.sin(theta),
        ],
        dtype=np.float32,
    )


def _stack_frames(frames: List[np.ndarray], need: int) -> np.ndarray:
    """Stack the last ``need`` (3, H, W) frames into (1, 3*need, H, W).

    Oldest first, current last. Front-pad with the oldest available frame when
    fewer than ``need`` frames are buffered (matches the run_omnivla_edge.py
    cold-start behaviour of duplicating the current frame). Pure numpy — unit
    testable without torch.
    """
    if not frames:
        raise RuntimeError('no observation frames buffered yet')
    padded = list(frames)
    while len(padded) < need:
        padded.insert(0, padded[0])
    stacked = np.concatenate(padded[-need:], axis=0)  # (3*need, H, W)
    return stacked[None, ...]


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


# Model hyper-parameters — straight from run_omnivla_edge.py's model_params.
# These define the architecture; they MUST match the omnivla-edge.pth checkpoint.
_MODEL_PARAMS = dict(
    context_size=5,
    len_traj_pred=8,
    learn_angle=True,
    obs_encoder='efficientnet-b0',
    obs_encoding_size=1024,
    late_fusion=False,
    mha_num_attention_heads=4,
    mha_num_attention_layers=4,
    mha_ff_dim_factor=4,
)


class OmniVLAEdgeLocalAdapter(EdgeAdapter):
    """Runs the full OmniVLA-edge policy on the robot (Plan 2B Path 2)."""

    def __init__(
        self,
        *,
        weights_path: str = '/workspace/models/omnivla-edge/omnivla-edge.pth',
        clip_type: str = 'ViT-B/32',
        device: str = 'cuda:0',
    ) -> None:
        # Heavy deps are imported lazily so the edge node starts fast for other
        # adapter kinds, and so unit tests of the pure helpers above don't need
        # torch / clip / efficientnet installed.
        import torch
        import clip

        if str(device).startswith('cpu'):
            raise ValueError(
                "OmniVLAEdgeLocalAdapter requires CUDA: the vendored OmniVLA_edge "
                "forward pass uses tensor.get_device() which is GPU-only. Pass a "
                "cuda device (e.g. 'cuda:0')."
            )
        if not torch.cuda.is_available():
            raise RuntimeError('CUDA not available but device=%r requested' % device)

        from ..models.omnivla_edge_model import OmniVLA_edge

        self._torch = torch
        self._clip = clip
        self._device = torch.device(device)
        self._context_size = int(_MODEL_PARAMS['context_size'])
        self._len_traj_pred = int(_MODEL_PARAMS['len_traj_pred'])

        if not os.path.exists(weights_path):
            raise FileNotFoundError(f'omnivla-edge weights not found at {weights_path}')

        _LOG.info('loading OmniVLA_edge from %s', weights_path)
        model = OmniVLA_edge(**_MODEL_PARAMS)
        state_dict = torch.load(weights_path, map_location=str(self._device))
        # The released omnivla-edge.pth is a bare state_dict (utils_policy.load_model
        # loads it with strict=True).
        model.load_state_dict(state_dict, strict=True)
        self._model = model.to(self._device).eval()

        _LOG.info('loading CLIP %s', clip_type)
        text_encoder, _preprocess = clip.load(clip_type, device=self._device, jit=False)
        self._text_encoder = text_encoder.to(torch.float32).to(self._device).eval()

        # Ring buffer of the last (context_size+1) ImageNet-normalized 96x96
        # frames (each (3, 96, 96)). Oldest first, current last.
        self._obs_ring: List[np.ndarray] = []
        self._goal: Optional[EdgeGoal] = None
        self._lock = threading.Lock()

        # Cache CLIP text features keyed by the prompt string — encode_text is
        # the only non-trivial per-goal cost and goals change rarely.
        self._text_cache_key: Optional[str] = None
        self._text_cache_feat = None  # torch.Tensor (1, 512)

        # Reusable zero-fill tensors.
        black96 = _black_chw(96)
        self._black96_chw = black96  # (3, 96, 96)

    @property
    def is_local(self) -> bool:
        # The whole policy runs here — the edge node needs no cloud.
        return True

    # -------------------------------------------------------------- goal intake

    def set_goal(self, goal: EdgeGoal) -> None:
        with self._lock:
            self._goal = goal

    # ----------------------------------------------------------------- internals

    def _push_frame(self, frame_chw: np.ndarray) -> None:
        self._obs_ring.append(frame_chw)
        if len(self._obs_ring) > self._context_size + 1:
            self._obs_ring.pop(0)

    def _stack_obs(self) -> np.ndarray:
        """-> (1, 3*(context_size+1), 96, 96). Front-pad with the oldest frame."""
        return _stack_frames(list(self._obs_ring), self._context_size + 1)

    def _text_features(self, text: str):
        torch = self._torch
        if text == self._text_cache_key and self._text_cache_feat is not None:
            return self._text_cache_feat
        tokens = self._clip.tokenize(text or 'xxxx', truncate=True).to(self._device)
        with torch.no_grad():
            feat = self._text_encoder.encode_text(tokens).to(torch.float32)
        self._text_cache_key = text
        self._text_cache_feat = feat
        return feat

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

        torch = self._torch

        # 1. Observation history.
        self._push_frame(_normalize_chw(cur_image_rgb, 96))
        obs_np = self._stack_obs()                       # (1, 18, 96, 96)
        obs_images = torch.from_numpy(obs_np).to(torch.float32).to(self._device)
        obs_image_cur = obs_images[:, -3:, :, :]         # last frame, (1, 3, 96, 96)
        cur_large = torch.from_numpy(
            _normalize_chw(cur_image_rgb, 224)[None, ...]
        ).to(torch.float32).to(self._device)             # (1, 3, 224, 224)

        # 2. Goal tensors.
        modality_id = _modality_id_for(goal.mode)

        if goal.pose_xy_theta is not None:
            goal_pose_np = _pose_goal_vector(goal.pose_xy_theta)
        else:
            goal_pose_np = np.zeros(4, dtype=np.float32)
        goal_pose = torch.from_numpy(goal_pose_np[None, ...]).to(torch.float32).to(self._device)

        if goal.mode == 'image' and goal.image_rgb is not None:
            goal_img_np = _normalize_chw(goal.image_rgb, 96)[None, ...]
        else:
            goal_img_np = self._black96_chw[None, ...]
        goal_image = torch.from_numpy(goal_img_np).to(torch.float32).to(self._device)

        # Zero-fill satellite map: cat(current_map, goal_map, obs_image_cur).
        black96 = torch.from_numpy(self._black96_chw[None, ...]).to(torch.float32).to(self._device)
        map_images = torch.cat((black96, black96, obs_image_cur), dim=1)  # (1, 9, 96, 96)

        feat_text = self._text_features(goal.text if goal.mode == 'text' else '')

        modality_id_t = torch.tensor([modality_id], device=self._device)

        # 3. Forward pass (single-frame batch).
        with torch.no_grad():
            action_pred, _dist_pred, _mask = self._model(
                obs_images,
                goal_pose,
                map_images,
                goal_image,
                modality_id_t,
                feat_text,
                cur_large,
            )
        waypoints = action_pred[0].float().cpu().numpy()  # (len_traj_pred, 4)

        # 4. Build the Path.
        return _trajectory_to_path(waypoints, frame_id=frame_id)
