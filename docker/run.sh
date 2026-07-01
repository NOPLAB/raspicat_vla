#!/usr/bin/env bash
# docker/run.sh — wrapper for building and running raspicat-vla Docker images.
#
# Subcommands:
#   build TARGET            asyncvla | omnivla | test | real | sim | --all
#   run MODEL --mode MODE [OPTS]
#                           MODEL = asyncvla | omnivla | omnivla_edge
#                           MODE  = remote {--cpu|--gpu} [--host BIND[:PORT]]
#                                   edge --host HOST[:PORT]
#                                   cmd_vel {--cpu|--gpu}   (remote+edge, no motors)
#                                   sim  --host HOST[:PORT]
#                                   edge-local              (omnivla_edge only)
#                           edge/cmd_vel/edge-local also take
#                                   --camera edge|realsense|/dev/videoN
#
# Run `run.sh --help` for the full reference.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRPC_PORT="${GRPC_PORT:-50051}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
HOST_ARCH="$(uname -m)"

# Jetson (L4T/aarch64) needs the ARM remote images + `--runtime nvidia` for GPU,
# not x86's `--gpus all`. Auto-detected from the host arch; force with
# RASPICAT_VLA_JETSON=1 (or =0 to disable, e.g. cross-build on an aarch64 host).
is_jetson() {
    case "${RASPICAT_VLA_JETSON:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    [[ $HOST_ARCH == aarch64 || $HOST_ARCH == arm64 ]]
}

# Image / Dockerfile / model knob registries. Bash 4 associative arrays.
declare -A IMAGES=(
    [asyncvla]="raspicat-vla-asyncvla"
    [omnivla]="raspicat-vla-omnivla"
    # omnivla_edge (Path 3) reuses the OmniVLA remote image (it adds CLIP +
    # efficientnet); the remote backend just loads a different checkpoint.
    [omnivla_edge]="raspicat-vla-omnivla"
    [asyncvla-jetson]="raspicat-vla-asyncvla-jetson"
    [omnivla-jetson]="raspicat-vla-omnivla-jetson"
    [omnivla_edge-jetson]="raspicat-vla-omnivla-jetson"
    [test]="raspicat-vla-test"
    [real]="raspicat-vla-real"
    [sim]="raspicat-vla-sim"
)
declare -A DOCKERFILES=(
    [asyncvla]="docker/Dockerfile.asyncvla"
    [omnivla]="docker/Dockerfile.omnivla"
    [asyncvla-jetson]="docker/Dockerfile.asyncvla.jetson"
    [omnivla-jetson]="docker/Dockerfile.omnivla.jetson"
    [test]="docker/Dockerfile.test"
    [real]="docker/Dockerfile.real"
    [sim]="docker/Dockerfile.sim"
)
declare -A RESUME_STEP=(
    [asyncvla]=750000
    [omnivla]=120000
    [omnivla_edge]=0      # unused: omnivla-edge.pth is a bare state_dict
)
declare -A WEIGHTS_DIR=(
    [asyncvla]="/workspace/models/AsyncVLA_release"
    [omnivla]="/workspace/models/omnivla-original"
    # For omnivla_edge --vla-path is the .pth weights file, not a checkpoint dir.
    [omnivla_edge]="/workspace/models/omnivla-edge/omnivla-edge.pth"
)

usage() {
    cat <<'EOF'
Usage: run.sh COMMAND [ARGS]

Commands:
  build TARGET            Build a Docker image
    TARGET = asyncvla | omnivla | test | real | sim | --all
             asyncvla-jetson | omnivla-jetson   (ARM64 / Jetson AGX Orin)
  run MODEL --mode MODE [OPTS]   Run a configuration
    MODEL = asyncvla | omnivla | omnivla_edge
    MODE (selected with --mode MODE):
      remote {--cpu|--gpu} [--host BIND[:PORT]]
                                    Host the cloud-side gRPC server here.
                                    Uses Dockerfile.<MODEL>. BIND defaults to
                                    0.0.0.0 (all interfaces). Optional :PORT
                                    overrides $GRPC_PORT.
      edge --host HOST[:PORT]       Edge stack here, talking to a cloud server
                                    at HOST:PORT (PORT defaults to $GRPC_PORT).
                                    Uses Dockerfile.real.

    Camera (edge | cmd_vel | edge-local):
      --camera edge|realsense|/dev/videoN
                                    Launch a camera node inside the edge
                                    container and publish frames on image_topic.
                                      edge        v4l2 webcam, default device
                                                  (/dev/video0) — a preset.
                                      /dev/videoN v4l2 webcam, explicit device.
                                                  Both are passed in via
                                                  `docker run --device`.
                                      realsense   Intel RealSense (realsense2_
                                                  camera); the container runs
                                                  privileged with /dev bind-
                                                  mounted for USB access.
                                    Omit to feed frames some other way (a camera
                                    launched outside, publish_fake_image.py, sim).
      cmd_vel {--cpu|--gpu}         All-in-one on THIS host, no real robot: one
                                    command starts BOTH the remote server (bound
                                    to 127.0.0.1) and the edge stack, in two
                                    containers. The follower publishes to a
                                    non-motor topic (/cmd_vel_vla), so the whole
                                    pipeline runs and cmd_vel is observable
                                    (ros2 topic echo /cmd_vel_vla) without driving
                                    the robot's motors. Feed frames with
                                    tools/publish_fake_image.py or a real camera.
      sim  --host HOST[:PORT]       Edge + Gazebo simulation, cloud at
                                    HOST:PORT. Uses Dockerfile.sim. Plan 3 wip.
      edge-local                    Plan 2B Path 2 (omnivla_edge ONLY): run the
                                    OmniVLA-edge policy ON the edge, standalone —
                                    no cloud, just edge node + follower
                                    (mvp_omnivla_edge.launch.py). Requires CUDA
                                    and models/omnivla-edge/omnivla-edge.pth.
                                    Uses Dockerfile.real; GPU via --gpus all
                                    (x86) or --runtime nvidia (Jetson/L4T).

    omnivla_edge modes (Plan 2B Path 3 — remote split, "Jetson infers, Pi
    controls"): --mode remote runs the OmniVLA-edge policy on this GPU box (the
    omnivla image + omnivla-edge.pth); the Pi side runs --mode edge/sim with the
    light path-only adapter (adapter_kind=omnivla, no torch). Path 2's
    --mode edge-local runs the whole thing on one CUDA box instead.
  test [PYTEST_ARGS...]   Run pytest in raspicat-vla-test (CPU). Auto-builds
                          the image if missing. Pass extra args to pytest:
                            run.sh test                        # full suite
                            run.sh test -k checkpoint          # filter
                            run.sh test src/raspicat_vla_edge/test  # subset
  help, -h, --help        Show this help

Examples:
  run.sh build asyncvla
  run.sh build --all
  run.sh run asyncvla --mode remote --gpu                  # bind 0.0.0.0:50051
  run.sh run asyncvla --mode remote --gpu --host :8080     # bind 0.0.0.0:8080
  run.sh run asyncvla --mode remote --cpu --host 127.0.0.1 # localhost only
  run.sh run omnivla  --mode remote --gpu --host 10.0.0.5:9000  # specific NIC + port
  run.sh run asyncvla --mode edge --host 192.168.1.2       # default port
  run.sh run asyncvla --mode edge --host 192.168.1.2:8080
  run.sh run omnivla  --mode edge --host 192.168.1.2 --camera edge       # v4l2 /dev/video0
  run.sh run omnivla  --mode edge --host 192.168.1.2 --camera /dev/cam1  # v4l2 explicit device
  run.sh run omnivla  --mode edge --host 192.168.1.2 --camera realsense  # Intel RealSense
  run.sh run omnivla  --mode cmd_vel --gpu                 # remote+edge here, no motors
  run.sh run omnivla  --mode sim  --host 192.168.1.2:9000
  run.sh run omnivla_edge --mode edge-local               # Path 2, standalone on-edge policy (GPU)
  run.sh run omnivla_edge --mode remote --gpu             # Path 3, OmniVLA-edge server (Jetson)
  run.sh run omnivla_edge --mode edge --host 192.168.1.2  # Path 3, Pi edge -> Jetson server
  run.sh test                                              # full pytest suite
  run.sh test -k omnivla                                   # filter by name

Jetson AGX Orin (ARM64):
  On an aarch64 host this script auto-selects the *-jetson remote images and
  swaps `--gpus all` for `--runtime nvidia`. Build + run on the device:
    run.sh build omnivla-jetson
    run.sh run omnivla --mode remote --gpu           # uses raspicat-vla-omnivla-jetson
  Match the image to your JetPack via Docker build args (see the Dockerfile
  header), e.g.:
    docker build -f docker/Dockerfile.omnivla.jetson \
      --build-arg L4T_BASE=nvcr.io/nvidia/l4t-jetpack:r36.4.0 \
      --build-arg TORCH_VERSION=2.8.0 -t raspicat-vla-omnivla-jetson .
  Force/disable Jetson mode with RASPICAT_VLA_JETSON=1 / =0.

Environment overrides:
  GRPC_PORT            gRPC port (default 50051)
  HF_CACHE_DIR         HuggingFace cache mount (default $HOME/.cache/huggingface)
  RASPICAT_VLA_JETSON  1 = force Jetson images + nvidia runtime; 0 = force x86
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[1;31m!!\033[0m  %s\n' "$*" >&2; }

# Resolve a --camera value to "KIND DEVICE" (space-separated) on stdout.
#   edge        -> v4l2 /dev/video0     (preset for the robot's default webcam)
#   /dev/*      -> v4l2 <path>          (explicit v4l2 device, e.g. /dev/cam1)
#   realsense   -> realsense <empty>    (Intel RealSense, driven over USB — no
#                                        device node path; realsense2_camera
#                                        enumerates it itself)
# Returns non-zero for anything else so the caller can reject typos.
resolve_camera() {
    case $1 in
        realsense) printf 'realsense \n' ;;
        edge)      printf 'v4l2 /dev/video0\n' ;;
        /dev/*)    printf 'v4l2 %s\n' "$1" ;;
        *)         return 1 ;;
    esac
}

# Docker args to expose a camera to a container that runs as `--user uid:gid`.
# $1 = camera kind (v4l2|realsense), $2 = device path (v4l2 only).
#  - v4l2: `--device` creates the node inside the container, but it is mode 660
#    root:video, so the unprivileged container user also needs the device's
#    owning group or open() fails with EACCES — emit `--group-add <gid>` (numeric
#    gid works even if the group name doesn't exist inside the container).
#  - realsense: the RealSense USB device re-enumerates on reset and spans several
#    /dev nodes, so bind-mount all of /dev and run privileged (the standard
#    librealsense-in-Docker recipe) rather than pinning one --device.
camera_docker_args() {
    local kind=$1 dev=$2
    case $kind in
        v4l2)
            [[ -n $dev ]] || return 0
            printf '%s\n' --device "$dev"
            [[ -e $dev ]] && printf '%s\n' --group-add "$(stat -c '%g' "$dev")"
            ;;
        realsense)
            printf '%s\n' --privileged -v /dev:/dev
            ;;
    esac
}

# Append camera_kind:=/camera_device:= to the launch argv array named by $1,
# skipping any that are empty — ROS2 rejects a bare `foo:=` with no value, and
# the launch files default both to '' (no camera node). $2 = kind, $3 = device.
_append_camera_launch_args() {
    local -n _arr=$1
    local kind=$2 dev=$3
    [[ -n $kind ]] && _arr+=("camera_kind:=${kind}")
    [[ -n $dev ]] && _arr+=("camera_device:=${dev}")
}

# split_hostport HOST[:PORT] DEFAULT_HOST DEFAULT_PORT -> "HOST PORT" on stdout.
# Empty HOST (e.g. ":8080") falls back to DEFAULT_HOST. Missing :PORT -> DEFAULT_PORT.
split_hostport() {
    local raw=$1 default_host=$2 default_port=$3
    local host port
    if [[ $raw == *:* ]]; then
        host=${raw%:*}
        port=${raw##*:}
    else
        host=$raw
        port=$default_port
    fi
    [[ -z $host ]] && host=$default_host
    if ! [[ $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "invalid port in '$raw'"
        return 1
    fi
    printf '%s %s\n' "$host" "$port"
}

build_one() {
    local target=$1
    local dfile_rel="${DOCKERFILES[$target]:-}"
    local image="${IMAGES[$target]:-}"
    [[ -n $dfile_rel && -n $image ]] || { err "unknown build target: $target"; return 1; }
    local dfile="${REPO_ROOT}/${dfile_rel}"
    [[ -f $dfile ]] || { err "Dockerfile not found: $dfile"; return 1; }
    if [[ $target == sim ]] && is_jetson; then
        warn "'sim' uses osrf/ros:humble-desktop-full, which has no arm64 image;"
        warn "this build will fail on Jetson with 'exec format error'. Use a x86 host for sim."
    fi
    log "building ${image} from ${dfile_rel}"
    docker build -f "$dfile" -t "$image" "$REPO_ROOT"
}

cmd_build() {
    local target=${1:-}
    case $target in
        --all)
            local rc=0 all_targets
            if is_jetson; then
                # On Jetson: build the ARM remote variants (the x86 ones have no
                # aarch64 cu121 torch wheel). Skip sim — its base image
                # (osrf/ros:humble-desktop-full) has no arm64 build, and a Gazebo
                # GUI workstation isn't a Jetson use case.
                all_targets=(asyncvla-jetson omnivla-jetson test real)
                warn "Jetson: skipping 'sim' from --all (osrf desktop-full has no arm64 image)."
            else
                all_targets=(asyncvla omnivla test real sim)
            fi
            for t in "${all_targets[@]}"; do
                build_one "$t" || rc=1
            done
            return $rc
            ;;
        asyncvla|omnivla|asyncvla-jetson|omnivla-jetson|test|real|sim)
            build_one "$target"
            ;;
        '')
            err "build: missing target"
            usage
            return 1
            ;;
        *)
            err "build: unknown target '$target'"
            usage
            return 1
            ;;
    esac
}

# Launch the cloud-side gRPC server container. Any args after the four fixed
# ones are passed verbatim to `docker run` (e.g. `--rm` for a foreground run, or
# `-d --rm --name X` to detach it — used by the cmd_vel mode). Shared by
# run_remote (foreground) and run_cmd_vel (detached).
_run_remote_server() {
    local model=$1 device=$2 bind_host=$3 bind_port=$4
    shift 4
    local docker_opts=("$@")
    local image="${IMAGES[$model]}"
    local resume_step="${RESUME_STEP[$model]}"
    local weights="${WEIGHTS_DIR[$model]}"
    # On Jetson the backend name (--backend / weights / resume-step) is unchanged;
    # only the container image (ARM build) and the GPU flag differ.
    if is_jetson; then
        image="${IMAGES[${model}-jetson]}"
    fi
    local gpu_flag="" device_arg="cpu"
    if [[ $device == gpu ]]; then
        # x86 uses the nvidia-container-toolkit's `--gpus all`; Jetson/L4T exposes
        # the iGPU through the nvidia container runtime instead.
        if is_jetson; then
            gpu_flag="--runtime nvidia"
        else
            gpu_flag="--gpus all"
        fi
        device_arg="cuda:0"
    fi

    log "${model} remote backend on ${device_arg}, bind ${bind_host}:${bind_port}"
    # The raspicat_vla_proto/raspicat_vla_remote packages are ROS2 ament_python
    # layouts (setup.cfg uses `script_dir`), so `pip install -e` fails on modern
    # setuptools. Run from source via PYTHONPATH instead.
    # shellcheck disable=SC2086
    docker run "${docker_opts[@]}" $gpu_flag --network host \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/root/.cache/huggingface" \
        "$image" bash -lc "
            cd /workspace
            export PYTHONPATH=/workspace/src/raspicat_vla_proto:/workspace/src/raspicat_vla_remote:/workspace/src/raspicat_vla_edge\${PYTHONPATH:+:\$PYTHONPATH}
            exec python3 -m raspicat_vla_remote.server_main \
                --backend ${model} \
                --host ${bind_host} \
                --port ${bind_port} \
                --vla-path ${weights} \
                --resume-step ${resume_step} \
                --device ${device_arg}
        "
}

run_remote() {
    local model=$1 device=$2 bind_host=$3 bind_port=$4
    _run_remote_server "$model" "$device" "$bind_host" "$bind_port" --rm
}

# Build raspicat-vla packages inside the container (idempotent — colcon
# detects already-built packages). Required because the rt-net packages are
# pre-built in /opt/sim_ws but the user-side raspicat_vla_* are mounted.
_workspace_build_cmd() {
    cat <<'BUILD'
if [ ! -f install/setup.bash ] || [ -n "$RASPICAT_VLA_REBUILD" ]; then
    echo "==> colcon build raspicat_vla_*" >&2
    colcon build --symlink-install \
        --packages-select raspicat_vla_msgs raspicat_vla_proto \
                          raspicat_vla_remote raspicat_vla_edge \
                          raspicat_vla_bringup
fi
source install/setup.bash
BUILD
}

# The edge-side adapter_kind for a remote MODEL. omnivla_edge (Path 3) runs the
# policy on the remote box, so the Pi uses the light path-only 'omnivla' adapter;
# every other model's edge adapter matches the model name.
edge_adapter_for() {
    local model=$1
    if [[ $model == omnivla_edge ]]; then printf 'omnivla\n'; else printf '%s\n' "$model"; fi
}

# Run the edge container (Dockerfile.real, falling back to the test image when
# real isn't built). $1 = model (for the fallback warnings); $2/$3 = camera kind
# ('' = none) + device path, expanded into `docker run` args by
# camera_docker_args; the rest is the `ros2 launch ...` argv to exec inside the
# container. Shared by run_edge and the edge half of run_cmd_vel.
_run_edge_launch() {
    local model=$1 camera_kind=$2 camera_device=$3
    shift 3
    local launch_argv=("$@")
    local device_args=()
    mapfile -t device_args < <(camera_docker_args "$camera_kind" "$camera_device")
    local image="${IMAGES[real]}"
    local has_real_image=true
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        has_real_image=false
        warn "image ${image} not built; falling back to ${IMAGES[test]} (no rt-net packages)."
        warn "run \`run.sh build real\` for the full image with raspicat_ros + Edge_adapter deps."
        image="${IMAGES[test]}"
        if [[ $model == asyncvla ]]; then
            warn "AsyncVLA edge needs torch + MBRA on PYTHONPATH; the test image lacks them."
        fi
    fi
    local source_real_ws=""
    if $has_real_image; then
        source_real_ws="source /opt/real_ws/install/setup.bash"
    fi
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e RASPICAT_VLA_REBUILD \
        --network host \
        "${device_args[@]}" \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/tmp/.cache/huggingface" \
        "$image" bash -lc "
            source /opt/ros/humble/setup.bash
            ${source_real_ws}
            cd /workspace
            $(_workspace_build_cmd)
            exec ${launch_argv[*]}
        "
}

run_edge() {
    local model=$1 host=$2 port=$3 camera_kind=${4:-} camera_device=${5:-}
    local adapter_kind
    adapter_kind=$(edge_adapter_for "$model")
    log "${model} edge (real); cloud=${host}:${port}${camera_kind:+; camera=${camera_kind}${camera_device:+ ${camera_device}}}"
    local launch_args=(
        ros2 launch raspicat_vla_edge edge_only.launch.py
        "remote_address:=${host}:${port}"
        "adapter_kind:=${adapter_kind}"
        with_follower:=true
    )
    _append_camera_launch_args launch_args "$camera_kind" "$camera_device"
    _run_edge_launch "$model" "$camera_kind" "$camera_device" "${launch_args[@]}"
}

# cmd_vel mode: one command, two containers, no real robot. Start the remote
# server detached (bound to 127.0.0.1) and the edge stack in the foreground; the
# edge runs cmd_vel.launch.py, whose follower publishes to /cmd_vel_vla (a
# non-motor topic) so the full pipeline runs and cmd_vel is observable without
# driving the robot's motors. When the edge exits (or Ctrl-C), tear the server
# down via the EXIT trap.
run_cmd_vel() {
    local model=$1 device=$2 camera_kind=${3:-} camera_device=${4:-}
    local port="$GRPC_PORT"
    local adapter_kind
    adapter_kind=$(edge_adapter_for "$model")
    local server_name="raspicat-vla-cmdvel-server-$$"

    log "cmd_vel: launching ${model} remote server + edge on this host (motors NOT driven)"
    # shellcheck disable=SC2064
    trap "docker rm -f '${server_name}' >/dev/null 2>&1 || true" EXIT INT TERM
    _run_remote_server "$model" "$device" "127.0.0.1" "$port" \
        -d --rm --name "$server_name" >/dev/null

    log "cmd_vel: edge -> 127.0.0.1:${port}; follower publishes /cmd_vel_vla (not /cmd_vel)${camera_kind:+; camera=${camera_kind}${camera_device:+ ${camera_device}}}"
    local launch_args=(
        ros2 launch raspicat_vla_bringup cmd_vel.launch.py
        "remote_address:=127.0.0.1:${port}"
        "adapter_kind:=${adapter_kind}"
    )
    _append_camera_launch_args launch_args "$camera_kind" "$camera_device"
    _run_edge_launch "$model" "$camera_kind" "$camera_device" "${launch_args[@]}"
}

run_sim() {
    local model=$1 host=$2 port=$3
    local image="${IMAGES[sim]}"
    local adapter_kind
    adapter_kind=$(edge_adapter_for "$model")
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        warn "image ${image} not built; falling back to ${IMAGES[test]} (no Gazebo)."
        warn "run \`run.sh build sim\` for the full sim image with Gazebo + raspicat_sim."
        image="${IMAGES[test]}"
        # Fallback: edge_only without Gazebo.
        log "${model} edge (sim-fallback, image=${image}); cloud=${host}:${port}"
        docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
            -e RASPICAT_VLA_REBUILD \
            --network host \
            -v "$REPO_ROOT:/workspace" \
            -v "$HF_CACHE_DIR:/tmp/.cache/huggingface" \
            "$image" bash -lc "
                source /opt/ros/humble/setup.bash
                cd /workspace
                $(_workspace_build_cmd)
                exec ros2 launch raspicat_vla_edge edge_only.launch.py \
                    remote_address:=${host}:${port} \
                    adapter_kind:=${adapter_kind} \
                    with_follower:=true
            "
        return
    fi

    # Full sim image with Gazebo. Forward DISPLAY so gzclient renders on the host.
    # Synthesize a /etc/passwd entry for the host UID inside the container so
    # gzclient stops spamming "Error getting username: no matching password record".
    # We can't bind-mount the host's /etc/passwd because Gazebo would then try
    # HOME=/home/<user> which doesn't exist in the image; the synthesized entry
    # points HOME at /tmp instead.
    local display_args=()
    if [[ -n ${DISPLAY:-} ]]; then
        display_args+=(-e "DISPLAY=$DISPLAY" -v "/tmp/.X11-unix:/tmp/.X11-unix:ro")
    fi

    # GPU passthrough for OpenGL. Gazebo renders the camera sensor (and gzclient)
    # via GL; on a software fallback (mesa/llvmpipe) that is so slow that gzserver
    # misses the spawn_entity service window and the robot never spawns. Hand the
    # NVIDIA GPU to the container when the nvidia container runtime is present.
    # NVIDIA_DRIVER_CAPABILITIES must include graphics+display (compute+utility
    # alone, the `--gpus all` default, give CUDA but no GL) so libGLX_nvidia is
    # injected. Skip with a warning if the runtime is missing — the run still
    # comes up on software GL, just slowly.
    local gpu_args=()
    if docker info 2>/dev/null | grep -q ' nvidia'; then
        gpu_args+=(--gpus all -e "NVIDIA_DRIVER_CAPABILITIES=all" -e "NVIDIA_VISIBLE_DEVICES=all")
    else
        warn "nvidia container runtime not found; sim falls back to software GL."
        warn "Gazebo camera rendering will be slow and spawn_entity may time out."
        warn "Install nvidia-container-toolkit + 'nvidia-ctk runtime configure --runtime=docker'."
    fi
    local uid gid passwd_dir
    uid=$(id -u); gid=$(id -g)
    passwd_dir=$(mktemp -d)
    cat /etc/passwd > "$passwd_dir/passwd"
    grep -q "^[^:]*:[^:]*:${uid}:" "$passwd_dir/passwd" || \
        echo "raspicat:x:${uid}:${gid}:raspicat:/tmp:/bin/bash" >> "$passwd_dir/passwd"
    cat /etc/group > "$passwd_dir/group"
    grep -q "^[^:]*:[^:]*:${gid}:" "$passwd_dir/group" || \
        echo "raspicat:x:${gid}:" >> "$passwd_dir/group"

    # Confine ROS2 DDS discovery to loopback/SHM. Every ROS node here (gzserver,
    # the edge node, the follower, …) lives in this one container; the only
    # remote link is the gRPC cloud connection, which is not ROS. With
    # ROS_LOCALHOST_ONLY=0 and --network host, FastDDS announces on every host
    # NIC including the LAN, and the resulting multi-participant discovery storm
    # makes gzserver's gazebo_ros_factory services (/spawn_entity) never get
    # matched — so spawn_entity times out and the robot never appears. Pinning to
    # localhost fixes that and isolates us from other ROS nodes on the LAN.
    log "${model} sim (image=${image}); cloud=${host}:${port}"
    docker run --rm --user "${uid}:${gid}" -e HOME=/tmp \
        -e ROS_LOCALHOST_ONLY=1 \
        --network host \
        "${gpu_args[@]}" \
        "${display_args[@]}" \
        -v "$passwd_dir/passwd:/etc/passwd:ro" \
        -v "$passwd_dir/group:/etc/group:ro" \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/tmp/.cache/huggingface" \
        "$image" bash -lc "
            source /opt/ros/humble/setup.bash
            source /opt/sim_ws/install/setup.bash
            cd /workspace
            $(_workspace_build_cmd)
            exec ros2 launch raspicat_vla_bringup mvp_sim.launch.py \
                remote_address:=${host}:${port} \
                adapter_kind:=${adapter_kind}
        "
}

# Plan 2B Path 2: the OmniVLA-edge policy runs entirely on the edge. The edge
# node operates standalone — no cloud, no gRPC, no embedding cache — so this is a
# single-host run of mvp_omnivla_edge.launch.py (edge node + follower). Needs
# CUDA (the vendored OmniVLA_edge forward pass is GPU-only) and the omnivla-edge
# weights at models/omnivla-edge/omnivla-edge.pth.
run_edge_local() {
    local camera_kind=${1:-} camera_device=${2:-}
    local image="${IMAGES[real]}"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        err "image ${image} not built; run \`run.sh build real\` first."
        return 1
    fi
    warn "Path 2 runs the OmniVLA-edge policy on-device and REQUIRES CUDA."
    warn "Dockerfile.real ships CPU torch; on a GPU host, rebuild it with a CUDA torch wheel."
    warn "Needs weights at models/omnivla-edge/omnivla-edge.pth (scripts/download_omnivla_edge_checkpoints.sh)."
    mkdir -p "${HOME}/.cache/clip"
    # x86 exposes the GPU via the nvidia-container-toolkit's `--gpus all`; Jetson/L4T
    # exposes the iGPU through the nvidia container runtime instead (`--gpus all`
    # invokes the prestart hook directly there and fails). Mirror run_remote().
    local gpu_flag="--gpus all"
    is_jetson && gpu_flag="--runtime nvidia"
    local device_args=()
    mapfile -t device_args < <(camera_docker_args "$camera_kind" "$camera_device")
    local cam_launch_args=()
    _append_camera_launch_args cam_launch_args "$camera_kind" "$camera_device"
    log "omnivla_edge edge-local (image=${image}, ${gpu_flag}); standalone edge + follower${camera_kind:+; camera=${camera_kind}${camera_device:+ ${camera_device}}}"
    # shellcheck disable=SC2086
    docker run --rm $gpu_flag --user "$(id -u):$(id -g)" -e HOME=/tmp \
        --network host \
        "${device_args[@]}" \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/tmp/.cache/huggingface" \
        -v "${HOME}/.cache/clip:/tmp/.cache/clip" \
        "$image" bash -lc "
            source /opt/ros/humble/setup.bash
            source /opt/real_ws/install/setup.bash
            cd /workspace
            $(_workspace_build_cmd)
            exec ros2 launch raspicat_vla_bringup mvp_omnivla_edge.launch.py \
                device:=cuda:0 ${cam_launch_args[*]}
        "
}

cmd_run() {
    local model=${1:-}
    case $model in
        asyncvla|omnivla|omnivla_edge) ;;
        '')
            err "run: missing model (asyncvla|omnivla|omnivla_edge)"; usage; return 1 ;;
        *)
            err "run: unknown model '$model'"; usage; return 1 ;;
    esac
    shift

    local mode='' host='' device='' camera=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode)
                [[ $# -ge 2 ]] || { err "--mode requires an argument (remote|edge|cmd_vel|sim|edge-local)"; return 1; }
                case $2 in
                    remote)     mode=remote ;;
                    edge)       mode=edge ;;
                    cmd_vel)    mode=cmd_vel ;;
                    sim)        mode=sim ;;
                    edge-local) mode=edge_local ;;
                    *) err "run: unknown mode '$2' (remote|edge|cmd_vel|sim|edge-local)"; return 1 ;;
                esac
                shift 2 ;;
            --host)
                [[ $# -ge 2 ]] || { err "--host requires an argument"; return 1; }
                host=$2; shift 2 ;;
            --camera)
                [[ $# -ge 2 ]] || { err "--camera requires an argument (edge|realsense|/dev/videoN)"; return 1; }
                camera=$2; shift 2 ;;
            --cpu)    device=cpu; shift ;;
            --gpu)    device=gpu; shift ;;
            -h|--help) usage; return 0 ;;
            *) err "run: unknown option '$1'"; usage; return 1 ;;
        esac
    done

    # --camera drives a camera node on the edge and needs the device exposed to
    # the container, so it only applies to the edge-side modes. remote hosts no
    # camera; sim gets its frames from Gazebo's virtual RealSense.
    local camera_kind='' camera_device=''
    if [[ -n $camera ]]; then
        case $mode in
            edge|cmd_vel|edge_local) ;;
            *) err "--camera is only valid for --mode edge|cmd_vel|edge-local (not '$mode')"; return 1 ;;
        esac
        local resolved
        resolved=$(resolve_camera "$camera") || {
            err "--camera: unknown value '$camera' (want edge|realsense|/dev/videoN)"; return 1
        }
        read -r camera_kind camera_device <<<"$resolved"
        # Only a v4l2 device is a host file we can pre-check; RealSense enumerates
        # over USB at run time.
        if [[ $camera_kind == v4l2 && ! -e $camera_device ]]; then
            warn "camera device ${camera_device} not present on host; passing it through anyway (edge will fail to open it if still absent at run time)"
        fi
    fi

    # --mode edge-local (Path 2, on-edge standalone policy) is only meaningful for
    # omnivla_edge. omnivla_edge additionally supports --mode remote (Path 3 server
    # on a GPU box / Jetson) and --mode edge/sim (the Pi-side edge, path-only adapter).
    if [[ $model != omnivla_edge && $mode == edge_local ]]; then
        err "--mode edge-local is only valid for model omnivla_edge"; return 1
    fi

    case $mode in
        edge_local)
            [[ -n $host ]] && warn "--host is ignored for --mode edge-local (standalone, no cloud)"
            run_edge_local "$camera_kind" "$camera_device"
            ;;
        remote)
            if [[ -z $device ]]; then
                err "--mode remote requires --cpu or --gpu"; return 1
            fi
            local pair bind_host bind_port
            pair=$(split_hostport "${host:-0.0.0.0}" "0.0.0.0" "$GRPC_PORT") || return 1
            read -r bind_host bind_port <<<"$pair"
            run_remote "$model" "$device" "$bind_host" "$bind_port"
            ;;
        cmd_vel)
            if [[ -z $device ]]; then
                err "--mode cmd_vel requires --cpu or --gpu (for the local remote server)"; return 1
            fi
            [[ -n $host ]] && warn "--host is ignored for --mode cmd_vel (server + edge both on 127.0.0.1)"
            run_cmd_vel "$model" "$device" "$camera_kind" "$camera_device"
            ;;
        edge|sim)
            [[ -n $host ]] || { err "--mode $mode requires --host HOST[:PORT]"; return 1; }
            local pair edge_host edge_port
            pair=$(split_hostport "$host" "" "$GRPC_PORT") || return 1
            read -r edge_host edge_port <<<"$pair"
            [[ -n $edge_host ]] || { err "--mode $mode --host needs a host part"; return 1; }
            "run_$mode" "$model" "$edge_host" "$edge_port" "$camera_kind" "$camera_device"
            ;;
        '')
            err "run: missing --mode (remote|edge|cmd_vel|sim|edge-local)"; usage; return 1 ;;
    esac
}

cmd_test() {
    local image="${IMAGES[test]}"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        warn "image ${image} not built; building first..."
        build_one test || return 1
    fi

    # Build the default test set: explicit files (not directories) because
    # ROS2's launch_testing pytest plugin claims directories and silently
    # drops every test in them ("collected 0 items / 1 skipped"). Smoke tests
    # guarded by ASYNCVLA_E2E / OMNIVLA_E2E env vars are included but skip
    # cleanly without GPU.
    local default_paths
    mapfile -t default_paths < <(
        find "$REPO_ROOT/src" -path '*/test/test_*.py' -not -path '*/__pycache__/*' \
            | sort \
            | sed "s|^$REPO_ROOT/||"
    )

    local args
    if [[ $# -eq 0 ]]; then
        args=(-v "${default_paths[@]}")
    else
        # Decide whether the user supplied any test path. Pure-flag invocations
        # (`run.sh test -k name`, `--lf`, `-x`) need default_paths prepended
        # so pytest doesn't fall back to cwd discovery (which would walk
        # external/ and crash on missing transitive deps).
        local has_path=false a
        for a in "$@"; do
            [[ -e $a || -e $REPO_ROOT/$a ]] && { has_path=true; break; }
        done
        if $has_path; then
            args=("$@")
        else
            args=("${default_paths[@]}" "$@")
        fi
    fi
    local args_str
    printf -v args_str '%q ' "${args[@]}"

    log "pytest in ${image} (${#args[@]} args)"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$REPO_ROOT:/workspace" \
        "$image" bash -lc "
            set -e
            source /opt/ros/humble/setup.bash
            cd /workspace
            $(_workspace_build_cmd)
            exec python3 -m pytest ${args_str}
        "
}

case ${1:-} in
    -h|--help|help|'') usage ;;
    build) shift; cmd_build "$@" ;;
    run)   shift; cmd_run "$@" ;;
    test)  shift; cmd_test "$@" ;;
    *) err "unknown command: '$1'"; usage; exit 1 ;;
esac
