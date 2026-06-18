# OmniVLA-edge on the edge (Plan 2B Path 2)

Implements the follow-up flagged at the end of
`docs/superpowers/plans/2026-04-30-omnivla-real-model-integration.md` ("After
Plan 2B"): run the full `OmniVLA_edge` policy **on the robot** instead of the
cloud-heavy Path 1.

## What runs where

- **Edge (standalone — no cloud)**: `adapter_kind=omnivla_edge_local` →
  `raspicat_vla_edge.adapters.omnivla_edge_local.OmniVLAEdgeLocalAdapter`.
  Loads the vendored `OmniVLA_edge` policy (EfficientNet-b0 encoders + FiLM +
  transformer decoder) and CLIP ViT-B/32, keeps a `context_size+1 = 6` frame
  ring buffer, and runs the whole forward pass per action tick.
- **Cloud**: none. Path 2 needs no remote backend at all.

The goal reaches the adapter via the new `EdgeAdapter.set_goal(EdgeGoal)` hook
(default no-op for cloud-heavy adapters) called from the edge node's goal sub.

### Standalone wiring in the edge node

`EdgeAdapter.is_local` (True only for `OmniVLAEdgeLocalAdapter`) flips the edge
node into standalone mode:

- `on_configure`: when `is_local`, the gRPC `VLAClient` is **not** created.
- `on_activate`: the observation-send loop is **not** started (nothing to send).
- `_action_tick`: routes to `_action_tick_local`, which bypasses the
  `EmbeddingCache` and calls `predict_path(embedding=None, cur_image_rgb=…)`
  directly from the latest frame. Empty Path (safe-stop) until a frame and a
  goal exist (the adapter returns an empty Path until `set_goal`).
- `_publish_status`: reports `OK` once image + goal are present, else
  `WAITING_REMOTE`.

The gRPC contract and the cloud-heavy adapters (stub / asyncvla / omnivla Path 1)
are unchanged — they still consume the cloud embedding via the cache.

## Files

- `src/raspicat_vla_edge/raspicat_vla_edge/models/omnivla_edge_model.py` —
  `OmniVLA_edge` vendored **verbatim** from
  `external/OmniVLA/inference/model_omnivla_edge.py` (so `load_state_dict(strict=True)`
  against `omnivla-edge.pth` matches exactly; do not rename anything here).
- `src/raspicat_vla_edge/raspicat_vla_edge/adapters/omnivla_edge_local.py` —
  the adapter: preprocessing, ring buffer, goal/modality handling, forward,
  `(len_traj_pred, 4)` waypoints → `nav_msgs/Path`.
- `adapters/base.py` — `EdgeGoal` dataclass + `set_goal` default no-op.
- `edge_node.py` — `omnivla_edge_local` dispatch, params, `set_goal` wiring,
  quaternion→yaw for pose goals.
- `config/edge_params.yaml` — `omnivla_edge_{weights_path,clip_type,device}`.
- `docker/Dockerfile.real` — CLIP (`--no-deps`) + ftfy/regex/tqdm.
- `scripts/download_omnivla_edge_checkpoints.sh` — NEW; fetches
  `NHirose/omnivla-edge` → `models/omnivla-edge/` (Path 1's
  `download_omnivla_checkpoints.sh` is unchanged, original-only).
- `launch/mvp_omnivla_edge.launch.py` — dummy heartbeat + on-edge adapter + follower.
- `test/test_omnivla_edge_local_adapter.py` — CPU unit tests for the pure
  helpers; full forward gated behind `OMNIVLA_EDGE_E2E=1`.

## Goal modalities (v1)

Single goal at a time (proto carries one `GoalSpec`): `text`→modality 7,
`pose`→4, `image`→6. Satellite/map inputs are zero-filled (masked out).

## Known limitations

1. **GPU-only.** The vendored `OmniVLA_edge.forward` uses
   `tensor.get_device()` (returns `-1` on CPU) and feeds it to `.to(device)`, so
   the adapter requires CUDA and rejects `device='cpu'`. Real raspicat hardware
   (Pi-class, no GPU) cannot run Path 2 as-is; a Jetson-class edge can. Note
   `Dockerfile.real` ships CPU torch — swap for a CUDA wheel on GPU edges.
2. **Pose goals are robot-relative.** With no tf/odometry on the edge, a `pose`
   goal's (x, y) are interpreted as robot-frame metres (x fwd, y left). Prefer
   `text` goals until edge localization is wired up.
3. **Not run here.** No GPU/weights/CLIP in the dev sandbox, so only the CPU
   unit tests ran (18 pass, E2E skipped). Verify the full forward on a CUDA host:
   `OMNIVLA_EDGE_E2E=1 pytest test/test_omnivla_edge_local_adapter.py -k full_forward`.

## Run

```bash
scripts/download_omnivla_edge_checkpoints.sh        # -> models/omnivla-edge/

# Standalone (no cloud): on-edge policy + follower, via docker/run.sh:
docker/run.sh run omnivla_edge --edge-local         # Dockerfile.real + --gpus all

# Or directly with ros2 launch on a CUDA edge:
ros2 launch raspicat_vla_bringup mvp_omnivla_edge.launch.py
```

Then publish RGB frames on the edge node's `image_topic` and a `GoalSpec` on
`goal_topic` — no remote server needed.

`run omnivla_edge --edge-local` uses `Dockerfile.real` with `--gpus all`. Because
that image ships CPU torch, rebuild it with a CUDA torch wheel on the GPU host
first (see the limitation above).
