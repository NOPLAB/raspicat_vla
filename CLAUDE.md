# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ROS2 Humble colcon workspace for running Vision-Language-Action navigation models on the rt-net `raspicat`. The repo splits the system into a lightweight **edge** stack (runs on the robot) and a heavy **remote** VLA policy server, connected by a single gRPC streaming interface defined in `proto/raspicat_vla.proto`. The same edge talks to three interchangeable backends: `dummy` (CI / Plan-1 MVP), `asyncvla` (Plan 2A), `omnivla` (Plan 2B).

## Repository layout (non-obvious parts)

- `src/raspicat_vla_*` — five colcon packages we own.
- `src/raspicat_{ros,description,sim,slam_navigation}` — rt-net source packages, **not in git**. They are imported by vcstool from `raspicat.repos` and `.gitignore`d. Re-run `vcs import src < raspicat.repos` after editing the manifest.
- `external/` — research submodules (`AsyncVLA`, `OmniVLA`, `MBRA`, `raspicat-sim-docker`). Reference code; **not built by colcon**. Vendored into the Docker images that need them (see `Dockerfile.real`/`.asyncvla`/`.omnivla`).
- `models/` — downloaded VLA weights. Gitignored, populated by `scripts/download_{asyncvla,omnivla,omnivla_edge}_checkpoints.sh`.
- `proto/raspicat_vla.proto` — source of truth for the gRPC interface. Generated stubs live at `src/raspicat_vla_proto/raspicat_vla_proto/raspicat_vla_pb2*.py` and are also gitignored — regenerate with `scripts/gen_proto.sh`.
- `scripts/sim_control.{sh,py}` — drive a running sim from the host (motor power + VLA goals); `.sh` is a thin wrapper that runs the `.py` helper inside the sim container.

## Architecture

**Edge / remote split with one gRPC service.** `VLAService.StreamInfer` is a bidirectional stream: edge sends `Observation` (JPEG image + `GoalSpec` + optional pose), remote returns `ActionEmbedding` (`(num_tokens, embed_dim)` fp16 tensor).

**Two ABCs define the swap points:**
- `raspicat_vla_remote.backends.base.VLABackend` — `infer(...) -> (embedding, metrics)`. Implemented by `DummyBackend`, `AsyncVLABackend`, `OmniVLABackend`. The generic `VLAServer` in `server.py` hosts any of these; selection happens in `server_main.py` via `--backend`.
- `raspicat_vla_edge.adapters.base.EdgeAdapter` — `predict_path(embedding, ...) -> nav_msgs/Path`. Selected at runtime by the `adapter_kind` ROS parameter (`stub` | `asyncvla` | `omnivla` | `omnivla_edge_local`; dispatched in `edge_node.py:_build_adapter`). Implementations: `StubAdapter`, `AsyncVLAEdgeAdapter` (runs the small Edge_adapter PyTorch model on-robot over `(cur, past, vla_feature)` and applies `delta_to_pose`), `OmniVLAEdgeAdapter` (`adapters/omnivla.py`), and `adapters/omnivla_edge_local.py` — the **Plan 2B Path 2** standalone policy that runs the *whole* OmniVLA-edge model on the robot with **no cloud** (edge node sets `local_mode`, skips gRPC, and the adapter consumes the raw observation instead of a remote embedding).

**Edge node is a LifecycleNode.** `VLAEdgeNode` has explicit `on_configure`/`on_activate`/`on_deactivate`/`on_cleanup`. Bringup launch files are responsible for emitting configure → activate transitions via `RegisterEventHandler` (see `mvp_local.launch.py`). Don't bypass this.

**Embedding cache and decoupled rates.** Edge publishes observations at `obs_publish_rate_hz` (default 2 Hz) but ticks the action loop at `action_rate_hz` (default 10 Hz). The latest embedding is held in `EmbeddingCache` with a soft `embedding_max_age_sec` and a hard timeout — when designing changes, preserve the property that the action tick consumes whatever is currently in cache rather than blocking on a fresh embedding. Relatedly, the gRPC client (`grpc_client.py`) **coalesces and paces** outbound observations: it keeps only the newest pending observation and rate-limits sends so a slow remote cannot back-pressure and stall the robot's control loop — preserve this when touching the send path.

**Cloud / edge symmetry for AsyncVLA.** Both the cloud backend (`backends/asyncvla.py`) and the edge adapter (`adapters/asyncvla.py`) need `external/MBRA` on `PYTHONPATH` (transitive dep `vint_train.models.vint.self_attention`) and the prismatic shim from `external/AsyncVLA`. Dockerfile.asyncvla / Dockerfile.real wire these up.

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
ros2 launch raspicat_vla_bringup mvp_local.launch.py
python3 tools/publish_fake_image.py   # inject a frame so something flows
```

### Docker (preferred — self-contained, matches CI)

`docker/run.sh` is the orchestrator. It manages images `test`, `real`, `sim`, `asyncvla`, `omnivla` (plus `asyncvla-jetson`/`omnivla-jetson` ARM64 variants).

```bash
docker/run.sh build TARGET           # asyncvla|omnivla|test|real|sim|--all
                                     #   | asyncvla-jetson|omnivla-jetson (ARM64)
docker/run.sh run MODEL --mode MODE [OPTS]
                                     # MODEL = asyncvla|omnivla|omnivla_edge
                                     # MODE (via --mode):
                                     #   remote  {--cpu|--gpu} [--host BIND[:PORT]]
                                     #   edge    --host HOST[:PORT]
                                     #   cmd_vel {--cpu|--gpu}   (remote+edge here, no motors)
                                     #   sim     --host HOST[:PORT]
                                     #   edge-local              (omnivla_edge only)
docker/run.sh test [PYTEST_ARGS...]  # full pytest in the test image
```

Mode selection is `--mode <value>` (not one flag per mode). `edge` is the on-robot edge stack talking to a remote server (formerly `--real`).

`--mode cmd_vel` is a single-host, no-real-robot bring-up: **one command starts two containers** — the remote server (bound to `127.0.0.1`) and the edge stack — and the follower publishes to a **non-motor topic** (`/cmd_vel_vla`, via `cmd_vel.launch.py`) so the full observation→gRPC→embedding→path→cmd_vel pipeline runs and is observable (`ros2 topic echo /cmd_vel_vla`) without driving the robot's motors. The server is detached and torn down on exit. Feed frames with `tools/publish_fake_image.py` or a real camera.

`--mode edge-local` is Plan 2B Path 2: run the OmniVLA-edge policy standalone **on the robot** (edge node + follower, `mvp_omnivla_edge.launch.py`, no cloud server). Needs CUDA and `models/omnivla-edge/omnivla-edge.pth`.

**Jetson AGX Orin (ARM64).** On an `aarch64` host `run.sh` auto-selects the `*-jetson` remote images and swaps `--gpus all` for `--runtime nvidia`. Build/run on-device with `build omnivla-jetson` / `run omnivla --mode remote --gpu`. Match the image to your JetPack via the `L4T_BASE`/`TORCH_VERSION` build args (see the Dockerfile header). Force/disable Jetson mode with `RASPICAT_VLA_JETSON=1`/`=0`. See `run.sh` `usage()` for the authoritative flag reference.

`run.sh test` rebuilds the test image on demand and **passes explicit test-file paths to pytest** because ROS2's `launch_testing` plugin claims directories and silently drops their tests. If you add a new `test_*.py`, the default-paths discovery (find -path `*/test/test_*.py`) will pick it up automatically; if you invoke pytest with bare flags (`-k foo`), `run.sh` still prepends the default paths so cwd discovery doesn't walk `external/` and crash.

Inside the `real`/`sim` containers, `run.sh` runs colcon for the `raspicat_vla_*` packages on every launch (idempotent — it skips when `install/setup.bash` already exists; force a rebuild with `RASPICAT_VLA_REBUILD=1`). The user-side packages are bind-mounted from `/workspace`, while the rt-net packages are pre-built into `/opt/{real,sim}_ws` at image build time.

### Regenerating gRPC stubs

```bash
scripts/gen_proto.sh   # writes src/raspicat_vla_proto/raspicat_vla_proto/raspicat_vla_pb2*.py
```

`grpc_tools.protoc` emits `import raspicat_vla_pb2` which the script rewrites to a relative import — keep that sed step if you change the generation flow.

### Downloading weights

```bash
scripts/download_asyncvla_checkpoints.sh      # -> models/AsyncVLA_release/  (~15 GB)
scripts/download_omnivla_checkpoints.sh       # -> models/omnivla-original/  (Path 1, cloud)
scripts/download_omnivla_edge_checkpoints.sh  # -> models/omnivla-edge/      (Path 2, on-robot)
```

Reuses `~/.cache/huggingface` so repeat runs are fast.

## Testing

```bash
docker/run.sh test                              # full suite
docker/run.sh test -k checkpoint                # filter by name
docker/run.sh test src/raspicat_vla_edge/test/test_pure_pursuit.py
```

Heavy integration tests that need GPUs/weights are gated by `ASYNCVLA_E2E` / `OMNIVLA_E2E` env vars and skip cleanly otherwise.

## Conventions worth knowing

- The `dummy` backend ignores image contents on purpose; the server falls back to a 1×1 placeholder on JPEG decode failure, which is why Plan-1 tests pass JPEG-shaped garbage. Real backends consume images via HF processors that fail noisily, so the silent fallback is safe in dummy-only paths.
- Action embeddings are transmitted as fp16 bytes (`embedding_fp16` in `ActionEmbedding`). Use `raspicat_vla_proto.conversions.{float32_array_to_fp16_bytes,fp16_bytes_to_float32_list}` rather than rolling your own conversions.
- The contract is `(num_tokens, embed_dim) float32` end to end — keep that shape consistent when adding a backend.
