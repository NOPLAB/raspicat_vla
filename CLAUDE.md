# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep only what the code can't tell you.** Invariants to preserve, why a decision was made, what's absent from the tree, and gotchas belong here. Don't duplicate API signatures, class/implementation lists, default parameter values, or CLI flags — read the source (or `vla.sh` usage output) for those, and delete anything here that a quick read would reveal.

## What this is

ROS2 Humble colcon workspace for running Vision-Language-Action navigation models on the rt-net `raspicat`. The repo splits the system into a lightweight **edge** stack (runs on the robot) and a heavy **remote** VLA policy server, connected by a single gRPC streaming interface defined in `proto/raspicat_vla.proto`. The same edge talks to three interchangeable backends: `dummy` (CI / Plan-1 MVP), `asyncvla` (Plan 2A), `omnivla` (Plan 2B).

A newer, **separate** effort (`app/`, `docs/design/mobile_port_spec.md`) ports OmniVLA-edge to run **on a smartphone** — the phone does camera capture + on-device ONNX inference and streams action chunks to the Pi, which only drives motors. This mirrors the Jetson "Path 3" topology with the phone replacing the Jetson. It does not go through `raspicat_vla.proto`; it has its own `proto/edge_action.proto`. `web/` (`docs/design/web_port_spec.md`) is the **browser** sibling of that port: same ONNX assets and data contract, inference via onnxruntime-web (WebGPU EP), chunks sent over WebSocket to the in-tree `edge_action_ws_server` (a JSON stand-in for `edge_action.proto`; the phone app uses the real gRPC server, `edge_action_grpc_server`).

## Repository layout (non-obvious parts)

- `src/raspicat_vla_*` — six colcon packages we own. `raspicat_vla_core` is the ROS-free OmniVLA-edge inference core (`OmniVLAEdgeEngine` + `models/`) shared by edge (Path 2) and remote (Path 3); keep it importable without rclpy/torch at module level — heavy deps are lazy-imported.
- `src/raspicat_{ros,description,sim,slam_navigation}` — rt-net source packages, **not in git**. They are imported by vcstool from `raspicat.repos` and `.gitignore`d. Re-run `vcs import src < raspicat.repos` after editing the manifest.
- `external/` — research submodules (`AsyncVLA`, `OmniVLA`, `MBRA`, `raspicat-sim-docker`, `movla`). Reference code; **not built by colcon**. Vendored into the Docker images that need them (see `Dockerfile.real`/`.asyncvla`/`.omnivla`/`.movla`). `movla` (github.com/NOPLAB/movla) is the in-house LFM2.5-VL Stage A policy served by `--backend movla`; keep its pin state_dict-compatible with the checkpoint being served (`ActionExpert`/`StateEncoder` keys are the contract — the upstream repo promises v1 checkpoint compatibility across refactors).
- `models/` — downloaded VLA weights. Gitignored, populated by `scripts/download_{asyncvla,omnivla,omnivla_edge}_checkpoints.sh`. movla checkpoints are **not on HF**: `scripts/download_movla_checkpoint.sh` rsyncs `runs/<run>/` from the training box (default `nop@pve1ubuntu`) into `models/movla/<run>/`.
- `proto/raspicat_vla.proto` — source of truth for the edge↔remote gRPC interface. Generated stubs live at `src/raspicat_vla_proto/raspicat_vla_proto/raspicat_vla_pb2*.py` and are also gitignored — regenerate with `scripts/gen_proto.sh`.
- `proto/edge_action.proto` — **independent** phone→Pi interface for the mobile port (`EdgeActionService.StreamActions`, phone = client, Pi = server). `scripts/gen_proto.sh` generates the Python stubs (gitignored, next to the raspicat_vla ones) **and** the Dart stubs at `app/inference/lib/src/grpc/gen/` (those are committed — the Flutter build has no protoc step; regeneration needs `dart pub global activate protoc_plugin`). The Pi-side server is `edge_action_grpc_node.py`, the gRPC twin of `edge_action_ws_node.py` — the two must keep the same slot+watchdog design (receive thread only fills a locked slot; a ROS timer publishes). Run it via `vla.sh run omnivla_edge_mobile --mode cmd_vel`.
- `app/` — Flutter (Android/iOS) apps; **not built by colcon**, separate Dart/Flutter toolchain. Two independent apps:
  - `app/inference/` (package `raspicat_vla_app`) — on-device OmniVLA-edge inference (the mobile port). `app/inference/assets/{models,clip}/` hold the ONNX weights + CLIP BPE vocab (gitignored, see their READMEs); absent → the app runs but falls back to dummy trajectories / zeroed text features.
  - `app/logger/` (package `vla_logger`) — VLA fine-tuning **data logger**: captures camera/IMU/GNSS/audio at a configurable period into raw per-session logs (`logger_sessions/<id>/`) for offline conversion to LeLaN/GNM/LeRobotDataset + prompt labeling. Does **no** inference, doesn't touch `raspicat_vla.proto`/`edge_action.proto`. Spec: `docs/design/logger_app_spec.md`; the on-disk contract is that spec's §3, produced by `lib/src/session/session_writer.dart`. In-app sync is deliberately absent — every sample carries a session-monotonic `t_mono_ns` and alignment is the converter's job.
- `web/` — React (Next.js static export) browser port of the mobile effort; **not built by colcon**, pnpm toolchain (see `web/README.md`). Runtime assets are all gitignored and restored by scripts: `pnpm sync-assets` copies the ONNX models + CLIP vocab from `app/inference/assets/`, and pnpm's postinstall copies the onnxruntime-web wasm runtime into `public/ort/`. Serve it from **localhost** — that keeps camera, WebGPU and `ws://` to the Pi all allowed at once (https blocks `ws://`, plain-http LAN blocks camera/WebGPU).
- `scripts/control.{sh,py}` — drive a running stack from the host (motor power + VLA goals); `.sh` is a thin wrapper that runs the `.py` helper inside the edge container. Mode-agnostic: it auto-detects the edge container across the real/sim/test images (override with `RASPICAT_VLA_CONTAINER`), so it works for `--mode edge`/`cmd_vel`/`sim`/`edge-local`. A bare `--mode remote` box runs no edge node, so there is nothing to control there.

## Architecture

**Edge / remote split with one gRPC service.** `VLAService.StreamInfer` (see `proto/raspicat_vla.proto`) is a bidirectional stream: edge sends observations, remote returns action embeddings. The contract is `(num_tokens, embed_dim)` float32 end to end — keep that shape when adding a backend.

**Two ABCs define the swap points.** `raspicat_vla_remote.backends.base.VLABackend` (cloud inference) is selected in `server_main.py` via `--backend`; `raspicat_vla_edge.adapters.base.EdgeAdapter` (embedding → `nav_msgs/Path`) is selected by the `adapter_kind` ROS parameter, dispatched in `edge_node.py:_build_adapter`. The non-obvious member is `omnivla_edge_local` (**Plan 2B Path 2**): it runs the *whole* OmniVLA-edge model on the robot with **no cloud** — the edge node sets `local_mode`, skips gRPC entirely, and the adapter consumes the raw observation instead of a remote embedding. Every other adapter assumes a remote embedding arrives.

**Mobile/web ports re-implement the OmniVLA-edge preprocessing by hand.** The Python engine (`raspicat_vla_core/omnivla_edge_engine.py`) is the reference definition; the Flutter app and the web app reproduce its resize / ImageNet-normalize / ring-buffer / goal-tensor assembly natively. `app/lib/src/config.dart` **and** `web/src/lib/config.ts` mirror the engine's `_MODEL_PARAMS` and must stay in lockstep — changing a constant on one side silently breaks agreement with `omnivla-edge.pth`. `docs/design/mobile_port_spec.md §3` is the authoritative data contract (7 ONNX inputs, output `(1,8,4)`); update it alongside any change.

**Edge node is a LifecycleNode.** Bringup launch files must drive the configure → activate transitions via the `edge_lifecycle_actions()` helper in `raspicat_vla_edge/launch_util.py` — don't bypass the lifecycle.

**Embedding cache and decoupled rates.** Edge publishes observations slower than it ticks the action loop; the latest embedding is held in `EmbeddingCache` with a soft max-age and a hard timeout. Preserve the property that the action tick consumes whatever is currently in cache rather than blocking on a fresh embedding. Relatedly, the gRPC client (`grpc_client.py`) **coalesces and paces** outbound observations — it keeps only the newest pending observation and rate-limits sends so a slow remote can't back-pressure and stall the control loop. Preserve this when touching the send path.

**Cloud / edge symmetry for AsyncVLA.** Both the cloud backend (`backends/asyncvla.py`) and the edge adapter (`adapters/asyncvla.py`) need `external/MBRA` on `PYTHONPATH` (transitive dep `vint_train.models.vint.self_attention`) and the prismatic shim from `external/AsyncVLA`. Dockerfile.asyncvla / Dockerfile.real wire these up.

**compose.yaml's `PYTHONPATH` replaces the image ENV.** The remote service's `environment: PYTHONPATH:` must re-list every vendored `/opt/...` source path the model images bake in (`/opt/OmniVLA`, `/opt/AsyncVLA`, `/opt/MBRA/train`, `/opt/movla/src`) — compose does not merge env vars, and dropping one silently breaks that backend's imports at run time (Python skips absent dirs, so one combined list serves all images). When adding a model image with vendored source, extend that list, not just the Dockerfile ENV.

**movla serves waypoints, not embeddings.** `--backend movla` (`backends/movla.py`) reuses the OmniVLA-edge Path 3 wire shape — metre-scaled `(horizon, 4)` `(x, y, cos, sin)` — so the edge runs the path-only `omnivla` adapter (see `edge_adapter_for` in vla.sh). Serving-time gotchas live in the backend docstring: the remote has no odometry, so history/velocity are pinned to the stationary padding the model saw at trajectory starts, and Stage A knows only the three template instructions; the raspicat embodiment is absent from the normalizer stats, so it serves as `turtlebot2` by default.

## Build & run

### Local colcon (host with ROS2 Humble installed)

First-time setup: fetch rt-net sources, resolve deps, build.

```bash
source /opt/ros/humble/setup.bash
vcs import src < raspicat.repos
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install
source install/setup.bash
```

To bump rt-net pins, edit `raspicat.repos` and re-run `vcs import`.

### Plan-1 MVP (dummy backend, all local)

```bash
ros2 launch raspicat_vla_bringup local_stack.launch.py   # backend:=dummy is the default
python3 tools/publish_fake_image.py   # inject a frame so something flows
```

`local_stack.launch.py` is the single-host no-Docker bring-up for every backend (`backend:=dummy|asyncvla|omnivla|omnivla_edge`); the per-model all-in-one launch files were folded into it.

### Docker (preferred — self-contained, matches CI)

`scripts/vla.sh` is the CLI (`build` / `run MODEL --mode MODE` / `test`), but the **container topology lives in `docker/compose.yaml`** — one compose profile per mode (see its header for the service map); `vla.sh` only parses flags, exports `VLA_*` variables, appends the structural overlays (`docker/compose.{gpu,jetson,camera-*,sim-display}.yaml`) and runs `docker compose up`. When changing how a mode runs, edit the compose files, not shell `docker run` plumbing. Run `vla.sh` with no args for the authoritative image, MODEL, MODE, and flag list — the notes below only cover what that usage text won't tell you.

Mode selection is `--mode <value>`, not one flag per mode. A few modes have non-obvious purpose:

- `--mode cmd_vel` is a single-host, no-real-robot bring-up: **one command starts two containers** (compose profile `cmd_vel` = remote server bound to `127.0.0.1` + edge stack) and the follower publishes to a **non-motor topic** (`/cmd_vel_vla`, via `edge_only.launch.py cmd_vel_topic:=/cmd_vel_vla`), so the full observation→gRPC→embedding→path→cmd_vel pipeline runs and is observable (`ros2 topic echo /cmd_vel_vla`) without driving motors. Both logs stream in the foreground; either container exiting stops the other.
- `--mode edge-local` (Plan 2B Path 2, `omnivla_edge` only) runs the OmniVLA-edge policy standalone **on the robot** (`omnivla_edge_local.launch.py`, no cloud server). Needs CUDA and `models/omnivla-edge/omnivla-edge.pth`.
- `omnivla_edge_mobile` (mobile port) only supports `--mode cmd_vel` and inverts the usual shape: **the phone is the camera and the model**, so one container runs just the `EdgeActionService` receiver + follower (`mobile_cmd_vel.launch.py`) — no VLA server, no `--cpu/--gpu/--camera`. Requires the `edge_action` stubs from `scripts/gen_proto.sh`.

**Jetson AGX Orin (ARM64).** On an `aarch64` host `vla.sh` auto-selects the `*-jetson` remote images and swaps `compose.gpu.yaml` (`gpus: all`) for `compose.jetson.yaml` (`runtime: nvidia`). Match the image to your JetPack via the `L4T_BASE`/`TORCH_VERSION` build args (see the Dockerfile header). Force/disable Jetson mode with `RASPICAT_VLA_JETSON=1`/`=0`.

`vla.sh test` rebuilds the test image on demand and **passes explicit test-file paths to pytest** because ROS2's `launch_testing` plugin claims directories and silently drops their tests. If you add a new `test_*.py`, the default-paths discovery (find -path `*/test/test_*.py`) will pick it up automatically; if you invoke pytest with bare flags (`-k foo`), `vla.sh` still prepends the default paths so cwd discovery doesn't walk `external/` and crash.

Inside the `real`/`sim` containers, `docker/ros_entrypoint.sh` runs colcon for the `raspicat_vla_*` packages on every launch (idempotent — it skips when `install/setup.bash` already exists; force a rebuild with `RASPICAT_VLA_REBUILD=1`). The user-side packages are bind-mounted from `/workspace`, while the rt-net packages are pre-built into `/opt/{real,sim}_ws` at image build time.

### Regenerating gRPC stubs

```bash
scripts/gen_proto.sh   # writes src/raspicat_vla_proto/raspicat_vla_proto/{raspicat_vla,edge_action}_pb2*.py
```

`grpc_tools.protoc` emits `import <name>_pb2` which the script rewrites to a relative import — keep that sed step if you change the generation flow. The script also emits the Dart stubs for `edge_action.proto` when `protoc-gen-dart` is installed, and skips them (with a hint) otherwise.

### Downloading weights

```bash
scripts/download_asyncvla_checkpoints.sh      # -> models/AsyncVLA_release/  (~15 GB)
scripts/download_omnivla_checkpoints.sh       # -> models/omnivla-original/  (Path 1, cloud)
scripts/download_omnivla_edge_checkpoints.sh  # -> models/omnivla-edge/      (Path 2, on-robot)
scripts/download_movla_checkpoint.sh [RUN]    # -> models/movla/<RUN>/       (rsync, not HF; default stage_a_v2)
```

Reuses `~/.cache/huggingface` so repeat runs are fast.

## Testing

```bash
scripts/vla.sh test                              # full suite
scripts/vla.sh test -k checkpoint                # filter by name
scripts/vla.sh test src/raspicat_vla_edge/test/test_pure_pursuit.py
```

Heavy integration tests that need GPUs/weights are gated by `ASYNCVLA_E2E` / `OMNIVLA_E2E` env vars and skip cleanly otherwise.

## Lint / Format

Configs live at the repo root: `.flake8` (shared by ament_flake8, CI, pre-commit) and `.pydocstyle`. Layers: per-package `test_flake8_*.py` / `test_pep257_*.py` run under `vla.sh test` (filename suffix avoids pytest module-name collisions in the one-shot run); CI is `.github/workflows/ci-lint.yml` (action-ros-lint); host-side `pre-commit` uses PyPI flake8/pydocstyle/autopep8 since no ROS is installed locally.

Non-obvious constraints:

- **ament_pep257 never reads config files** (its own CLI args always win), so the pep257 ignore list is duplicated in four places that must stay in sync: `.pydocstyle`, each `test_pep257_*.py`, `ci-lint.yml`, and nowhere in CMake — the bringup/msgs `colcon test` skips pep257 entirely because humble's `find_package(ament_cmake_pep257)` unconditionally re-registers the auto hook (duplicate test name) and the hook can't take arguments; CI covers those packages instead.
- `omnivla_edge_model.py` (vendored verbatim, checkpoint contract) and `*_pb2*.py` (generated) are excluded from every linter/formatter — when adding an exclusion, remember flake8's bare patterns match any same-named directory (use `./`-anchored entries for repo-root dirs; that's how `models` once silently skipped `raspicat_vla_core/.../models/`).
- Intentionally disabled rule families: import-order (I…, no autofixer, large existing divergence), D213 (ROS-core second-line summary style vs this repo's first-line style), D400/D401/D403/D415 (English-prose rules that fight Japanese docstrings), D406/D407/D413 (numpy sections vs Google style).

## Conventions worth knowing

- The `dummy` backend ignores image contents on purpose; the server falls back to a 1×1 placeholder on JPEG decode failure, which is why Plan-1 tests pass JPEG-shaped garbage. Real backends consume images via HF processors that fail noisily, so the silent fallback is safe in dummy-only paths.
- Action embeddings travel the wire as fp16 bytes. Use `raspicat_vla_proto.conversions.{float32_array_to_fp16_bytes,fp16_bytes_to_float32_list}` rather than rolling your own conversions.
