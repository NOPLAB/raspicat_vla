#!/usr/bin/env bash
# sim_control.sh — drive a running raspicat_vla sim: motor power + VLA goals.
#
# Thin host wrapper around scripts/sim_control.py. It runs the Python helper
# inside the running sim container (where rclpy + the raspicat_vla_msgs overlay
# live), sourcing the ROS overlays first. /workspace is bind-mounted into the
# container, so the helper is reached at /workspace/scripts/sim_control.py.
#
# Usage:
#   scripts/sim_control.sh motor on|off
#   scripts/sim_control.sh goal pose X Y [THETA] [FRAME]    # FRAME default: odom
#   scripts/sim_control.sh goal text "go down the hallway"
#   scripts/sim_control.sh goal image /workspace/path/to.jpg
#   scripts/sim_control.sh stop
#   scripts/sim_control.sh status
#
# First run is typically:  scripts/sim_control.sh motor on
#                          scripts/sim_control.sh goal pose 2 0
#
# Override the container with RASPICAT_SIM_CONTAINER=<name-or-id>. If a ROS
# environment with raspicat_vla_msgs is already on PATH (e.g. you're inside the
# container), it runs the helper directly instead of via docker exec.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_IMAGE="${RASPICAT_VLA_SIM_IMAGE:-raspicat-vla-sim}"

# Already inside a ROS env with our messages? Run directly.
if python3 -c 'import rclpy, raspicat_vla_msgs.msg' >/dev/null 2>&1; then
    exec python3 "${REPO_ROOT}/scripts/sim_control.py" "$@"
fi

cid="${RASPICAT_SIM_CONTAINER:-}"
if [[ -z $cid ]]; then
    cid="$(docker ps -q --filter "ancestor=${SIM_IMAGE}" | head -1)"
fi
if [[ -z $cid ]]; then
    echo "error: no running '${SIM_IMAGE}' container found." >&2
    echo "       start the sim first, e.g.:" >&2
    echo "       docker/run.sh run omnivla --sim --host HOST:PORT" >&2
    echo "       (or set RASPICAT_SIM_CONTAINER=<name-or-id>)" >&2
    exit 1
fi

# Build a safely-quoted arg list for the inner shell.
quoted=""
for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
done

exec docker exec "$cid" bash -lc "
    source /opt/ros/humble/setup.bash
    [ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash
    exec python3 /workspace/scripts/sim_control.py${quoted}
"
