# raspicat-vla

[![ci-lint](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-lint.yml/badge.svg?branch=main)](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-lint.yml)
[![ci-flutter](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-flutter.yml/badge.svg?branch=main)](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-flutter.yml)
[![ci-web](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-web.yml/badge.svg?branch=main)](https://github.com/NOPLAB/raspicat-vla/actions/workflows/ci-web.yml)

ROS2 Humble nodes for running Vision-Language-Action (VLA) navigation models on
the Raspberry Pi Cat (rt-net `raspicat`).

The repository defines a model-agnostic edge / remote split: the lightweight
edge runs on the robot, a remote workstation hosts the heavy VLA policy, and a
gRPC stream carries observations one way and action embeddings the other. The
same interface supports multiple backends — the dummy server (for CI / MVP),
[AsyncVLA](https://asyncvla.github.io/), and
[OmniVLA](https://omnivla-nav.github.io/). For OmniVLA-edge the policy can also
run fully on-robot with no cloud (`--mode edge-local`).

A separate effort ports OmniVLA-edge off the workstation entirely:

- `app/` — Flutter smartphone app: on-device ONNX inference; the phone streams
  action chunks to the Pi over its own gRPC interface
  (`proto/edge_action.proto`). See [`docs/design/mobile_port_spec.md`](docs/design/mobile_port_spec.md).
- `web/` — browser sibling of the mobile port (Next.js static export,
  onnxruntime-web / WebGPU); chunks go to the Pi over WebSocket. See
  [`docs/design/web_port_spec.md`](docs/design/web_port_spec.md).

## Workspace layout

This repository is itself a colcon workspace.

```
src/raspicat_vla_msgs/      # ROS2 messages, services, actions (model-agnostic)
src/raspicat_vla_proto/     # gRPC python stubs + ROS2 ⇄ proto conversion helpers
src/raspicat_vla_core/      # ROS-free OmniVLA-edge inference core (shared by edge & remote)
src/raspicat_vla_remote/    # gRPC server: dummy / AsyncVLA / OmniVLA backends
src/raspicat_vla_edge/      # Edge ROS2 nodes (lifecycle, adapters, path follower,
                            #   phone/browser action receivers)
src/raspicat_vla_bringup/   # Launch composition
```

Not built by colcon:

```
app/                        # Flutter smartphone port (Dart toolchain, see app/README.md)
web/                        # Browser port (pnpm toolchain, see web/README.md)
docker/                     # Dockerfiles + compose topology for every run mode
external/                   # Research submodules: AsyncVLA, OmniVLA, MBRA,
                            #   raspicat-sim-docker (reference code)
models/                     # VLA weights, gitignored — scripts/download_*.sh
```

The rt-net ROS2 source packages (`raspicat_ros`, `raspicat_description`,
`raspicat_sim`, `raspicat_slam_navigation`) are managed via vcstool, not
submodules — see `raspicat.repos`.

## gRPC interfaces

`proto/raspicat_vla.proto` defines the model-agnostic edge ↔ remote service
`raspicat_vla.v1.VLAService`:

- `StreamInfer(stream Observation) returns (stream ActionEmbedding)`
- `GetModelInfo(ModelInfoRequest) returns (ModelInfo)`

`proto/edge_action.proto` is the independent phone → Pi interface for the
mobile port (`EdgeActionService.StreamActions`; the phone is the client, the
Pi the server).

`scripts/gen_proto.sh` regenerates the Python stubs for both (into
`src/raspicat_vla_proto/raspicat_vla_proto/`, gitignored) and the Dart stubs
for `edge_action.proto` (into `app/lib/src/grpc/gen/`, committed).

## Build

First-time setup fetches the rt-net source packages into `src/` via vcstool,
then resolves their transitive ROS dependencies via rosdep:

```bash
source /opt/ros/humble/setup.bash
vcs import src < raspicat.repos              # one-time / on raspicat.repos changes
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install
source install/setup.bash
```

To bump the pinned rt-net versions, edit `raspicat.repos` and re-run
`vcs import src < raspicat.repos`.

## Running

`scripts/vla.sh` is the primary entry point for build/run/test. A run is
`vla.sh run MODEL --mode MODE`; the container topology behind each mode is
declared in `docker/compose.yaml` (one compose profile per mode). Run
`scripts/vla.sh` with no arguments for the authoritative MODEL / MODE / flag
list; the full operator guide lives at [`docs/USAGE.md`](docs/USAGE.md). A
quick orientation:

* `scripts/vla.sh build TARGET` — build one of the images
  (`asyncvla`, `omnivla`, `real`, `sim`, `test`, plus `*-jetson` for ARM64).
* `--mode remote {--cpu|--gpu}` — host the cloud-side gRPC server here.
* `--mode edge --host HOST[:PORT]` — on-robot edge stack pointed at a remote.
* `--mode cmd_vel` — all-in-one on this host, no robot: remote + edge in two
  containers, follower on a non-motor topic (`/cmd_vel_vla`).
* `--mode sim --host HOST[:PORT]` — Gazebo + edge.
* `--mode edge-local` — OmniVLA-edge policy standalone on the robot, no cloud
  (needs CUDA + `models/omnivla-edge/omnivla-edge.pth`).
* `run omnivla_edge_mobile --mode cmd_vel` — Pi side of the mobile port: the
  phone infers, this host receives action chunks and follows.
* `scripts/vla.sh test [PYTEST_ARGS...]` — pytest in the CPU test image.

For a no-Docker single-host bring-up there is
`ros2 launch raspicat_vla_bringup local_stack.launch.py backend:=dummy|asyncvla|omnivla|omnivla_edge`.

With a stack running, `scripts/control.sh` drives it from the host (motor
power + VLA goals).

Both `asyncvla` and `omnivla` backends work on CPU but are slow; GPU is
strongly recommended for anything beyond wiring smoke tests. See
[`docs/USAGE.md`](docs/USAGE.md) §5.6 for CPU-specific caveats.
