#!/usr/bin/env bash
# bash.sh — drop into an interactive bash inside a lightweight ROS2 Humble image.
#
# Unlike scripts/vla.sh (which builds and runs the heavy real/sim/remote images),
# this spins up the stock `ros:humble-ros-base` image — no Gazebo, no desktop, no
# CUDA, no colcon build — just a shell with the core ROS2 CLI (`ros2 topic`,
# `ros2 node`, rclpy, …) already on PATH. Handy for poking at a running stack,
# echoing topics, or trying `ros2` commands without waiting on a workspace build.
#
# The repo is bind-mounted at /workspace (the working directory), so files you
# touch are the real ones on the host. If a colcon overlay has been built
# (install/setup.bash present) it is sourced on top of the base ROS2 env; if not,
# only /opt/ros/humble is available — that's expected for a bare shell.
#
# Usage:
#   scripts/bash.sh                     # interactive bash
#   scripts/bash.sh ros2 topic list     # run one command, then exit
#
# ROS_DOMAIN_ID is forwarded from the host when set, so this joins the same DDS
# domain as any edge/remote container already running via vla.sh. Networking is
# --network host for exactly that reason.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${RASPICAT_VLA_BASE_IMAGE:-ros:humble-ros-base}"

# Map the host user so files created under the bind-mounted /workspace are owned
# by you, not root. The mapped uid has no /etc/passwd entry, hence HOME=/tmp.
docker_args=(
    --rm -i
    --user "$(id -u):$(id -g)" -e HOME=/tmp
    --network host
    -v "$REPO_ROOT:/workspace" -w /workspace
)
# Allocate a TTY only when we actually have one, so piped/CI use (e.g.
# `scripts/bash.sh ros2 topic list | grep foo`) doesn't trip docker's
# "cannot attach stdin to a TTY-enabled container".
[[ -t 0 && -t 1 ]] && docker_args+=(-t)
[[ -n ${ROS_DOMAIN_ID:-} ]] && docker_args+=(-e "ROS_DOMAIN_ID=${ROS_DOMAIN_ID}")

# Build a safely-quoted command for the inner login shell: default to bash if no
# args were given, otherwise exec the passed argv verbatim.
if (($# == 0)); then
    inner="exec bash"
else
    quoted=""
    for a in "$@"; do
        quoted+=" $(printf '%q' "$a")"
    done
    inner="exec${quoted}"
fi

exec docker run "${docker_args[@]}" "$IMAGE" bash -lc "
    source /opt/ros/humble/setup.bash
    [ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash
    ${inner}
"
