#!/usr/bin/env bash
# docker/ros_entrypoint.sh — in-container bootstrap shared by every ROS service
# in docker/compose.yaml (edge / sim / edge-local / test).
#
# Sources ROS + the prebuilt rt-net overlay (VLA_WS_OVERLAY, skipped when the
# image doesn't have one, e.g. the test-image fallback), then (re)builds the
# bind-mounted raspicat_vla_* packages into /workspace/install and execs the
# service command. The build is idempotent: it only runs when a package is
# missing from install/ (a newly added package with a stale overlay counts) or
# when RASPICAT_VLA_REBUILD is set.
set -e

source /opt/ros/humble/setup.bash
if [[ -n ${VLA_WS_OVERLAY:-} && -f ${VLA_WS_OVERLAY} ]]; then
    source "${VLA_WS_OVERLAY}"
fi

cd /workspace
_vla_pkgs=(raspicat_vla_msgs raspicat_vla_proto raspicat_vla_core
           raspicat_vla_remote raspicat_vla_edge raspicat_vla_bringup)
_need_build=${RASPICAT_VLA_REBUILD:-}
for _p in "${_vla_pkgs[@]}"; do
    [[ -d "install/${_p}" ]] || _need_build=1
done
if [[ -n ${_need_build} ]]; then
    echo "==> colcon build raspicat_vla_*" >&2
    colcon build --symlink-install --packages-select "${_vla_pkgs[@]}"
fi
source install/setup.bash

exec "$@"
