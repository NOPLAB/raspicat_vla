#!/usr/bin/env bash
# control.sh — drive a running raspicat_vla stack: motor power + VLA goals.
#
# Works against whichever vla.sh mode is up — edge, cmd_vel, sim, or edge-local
# — because all of them run the same edge node, which subscribes to the goal
# topic and (where a robot/raspimouse is present) offers the /motor_power
# service. There is nothing to control in a bare `--mode remote` box: that
# container is a headless gRPC server with no ROS node, no goal subscriber, and
# no motors. Point this at the host running the *edge* side instead.
#
# Thin host wrapper around scripts/control.py: it runs the Python helper inside
# the running edge container (where rclpy + the raspicat_vla_msgs overlay live),
# sourcing the ROS overlays first. /workspace is bind-mounted into the container,
# so the helper is reached at /workspace/scripts/control.py.
#
# Usage:
#   scripts/control.sh motor on|off
#   scripts/control.sh goal pose X Y [THETA] [FRAME]    # FRAME default: odom
#   scripts/control.sh goal text "go down the hallway"
#   scripts/control.sh goal image /workspace/path/to.jpg
#   scripts/control.sh stop                             # motor off (coast to halt)
#   scripts/control.sh status
#
# First run is typically:  scripts/control.sh motor on
#                          scripts/control.sh goal pose 2 0
#
# Container selection: by default we probe the edge-capable images in order
# (real, sim, test) and use the first running container. Override with
# RASPICAT_VLA_CONTAINER=<name-or-id> to pin one explicitly (RASPICAT_SIM_CONTAINER
# is still honoured for backward compatibility). If a ROS environment with
# raspicat_vla_msgs is already on PATH (e.g. you're inside the container), the
# helper runs directly instead of via docker exec.
#
# ROS_DOMAIN_ID: if set in the host environment it is forwarded into the
# container so the helper talks on the same DDS domain as the edge node. In the
# direct-run path it is already inherited from the host env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Already inside a ROS env with our messages? Run directly.
if python3 -c 'import rclpy, raspicat_vla_msgs.msg' >/dev/null 2>&1; then
    exec python3 "${REPO_ROOT}/scripts/control.py" "$@"
fi

# Edge-capable images, most-specific first. The edge node — the thing that owns
# the goal topic + motor service — runs in one of these; the remote server
# images (omnivla/asyncvla) run no ROS node, so they are intentionally omitted.
CANDIDATE_IMAGES=(
    "${RASPICAT_VLA_REAL_IMAGE:-raspicat-vla-real}"
    "${RASPICAT_VLA_SIM_IMAGE:-raspicat-vla-sim}"
    "${RASPICAT_VLA_TEST_IMAGE:-raspicat-vla-test}"
)

cid="${RASPICAT_VLA_CONTAINER:-${RASPICAT_SIM_CONTAINER:-}}"
if [[ -z $cid ]]; then
    for img in "${CANDIDATE_IMAGES[@]}"; do
        cid="$(docker ps -q --filter "ancestor=${img}" | head -1)"
        [[ -n $cid ]] && break
    done
fi
if [[ -z $cid ]]; then
    echo "error: no running raspicat-vla edge container found." >&2
    echo "       looked for images: ${CANDIDATE_IMAGES[*]}" >&2
    echo "       start the edge side first, e.g.:" >&2
    echo "         scripts/vla.sh run omnivla --mode cmd_vel --gpu" >&2
    echo "         scripts/vla.sh run omnivla --mode edge --host HOST:PORT" >&2
    echo "         scripts/vla.sh run omnivla --mode sim  --host HOST:PORT" >&2
    echo "       (or set RASPICAT_VLA_CONTAINER=<name-or-id>)" >&2
    exit 1
fi

# Build a safely-quoted arg list for the inner shell.
quoted=""
for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
done

# Forward ROS_DOMAIN_ID into the container when it is set on the host, so the
# helper joins the same DDS domain as the running edge node.
exec_env=()
if [[ -n ${ROS_DOMAIN_ID:-} ]]; then
    exec_env+=(-e "ROS_DOMAIN_ID=${ROS_DOMAIN_ID}")
fi

exec docker exec "${exec_env[@]}" "$cid" bash -lc "
    source /opt/ros/humble/setup.bash
    [ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash
    exec python3 /workspace/scripts/control.py${quoted}
"
