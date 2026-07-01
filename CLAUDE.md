# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep only what the code can't tell you.** Invariants to preserve, why a decision was made, what's absent from the tree, and gotchas belong here. Don't duplicate API signatures, class/implementation lists, default parameter values, or CLI flags — read the source (or `run.sh` usage output) for those, and delete anything here that a quick read would reveal.

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

**Edge / remote split with one gRPC service.** `VLAService.StreamInfer` (see `proto/raspicat_vla.proto`) is a bidirectional stream: edge sends observations, remote returns action embeddings. The contract is `(num_tokens, embed_dim)` float32 end to end — keep that shape when adding a backend.

**Two ABCs define the swap points.** `raspicat_vla_remote.backends.base.VLABackend` (cloud inference) is selected in `server_main.py` via `--backend`; `raspicat_vla_edge.adapters.base.EdgeAdapter` (embedding → `nav_msgs/Path`) is selected by the `adapter_kind` ROS parameter, dispatched in `edge_node.py:_build_adapter`. The non-obvious member is `omnivla_edge_local` (**Plan 2B Path 2**): it runs the *whole* OmniVLA-edge model on the robot with **no cloud** — the edge node sets `local_mode`, skips gRPC entirely, and the adapter consumes the raw observation instead of a remote embedding. Every other adapter assumes a remote embedding arrives.

**Edge node is a LifecycleNode.** Bringup launch files must drive the configure → activate transitions via `RegisterEventHandler` (see `mvp_local.launch.py`) — don't bypass the lifecycle.

**Embedding cache and decoupled rates.** Edge publishes observations slower than it ticks the action loop; the latest embedding is held in `EmbeddingCache` with a soft max-age and a hard timeout. Preserve the property that the action tick consumes whatever is currently in cache rather than blocking on a fresh embedding. Relatedly, the gRPC client (`grpc_client.py`) **coalesces and paces** outbound observations — it keeps only the newest pending observation and rate-limits sends so a slow remote can't back-pressure and stall the control loop. Preserve this when touching the send path.

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

`docker/run.sh` is the orchestrator (`build` / `run MODEL --mode MODE` / `test`). Run it with no args for the authoritative image, MODEL, MODE, and flag list — the notes below only cover what that usage text won't tell you.

Mode selection is `--mode <value>`, not one flag per mode. A few modes have non-obvious purpose:

- `--mode cmd_vel` is a single-host, no-real-robot bring-up: **one command starts two containers** (remote server bound to `127.0.0.1` + edge stack) and the follower publishes to a **non-motor topic** (`/cmd_vel_vla`, via `cmd_vel.launch.py`), so the full observation→gRPC→embedding→path→cmd_vel pipeline runs and is observable (`ros2 topic echo /cmd_vel_vla`) without driving motors. The server is detached and torn down on exit.
- `--mode edge-local` (Plan 2B Path 2, `omnivla_edge` only) runs the OmniVLA-edge policy standalone **on the robot** (`mvp_omnivla_edge.launch.py`, no cloud server). Needs CUDA and `models/omnivla-edge/omnivla-edge.pth`.

**Jetson AGX Orin (ARM64).** On an `aarch64` host `run.sh` auto-selects the `*-jetson` remote images and swaps `--gpus all` for `--runtime nvidia`. Match the image to your JetPack via the `L4T_BASE`/`TORCH_VERSION` build args (see the Dockerfile header). Force/disable Jetson mode with `RASPICAT_VLA_JETSON=1`/`=0`.

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
- Action embeddings travel the wire as fp16 bytes. Use `raspicat_vla_proto.conversions.{float32_array_to_fp16_bytes,fp16_bytes_to_float32_list}` rather than rolling your own conversions.
