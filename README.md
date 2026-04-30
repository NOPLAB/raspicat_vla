# raspicat-vla

ROS2 Humble nodes for running VLA navigation on the Raspberry Pi Cat (rt-net `raspicat`).

## Workspace layout

This repository is itself a colcon workspace.

```
src/raspicat_async_vla_msgs/      # ROS2 messages, services, actions
src/raspicat_async_vla_proto/     # gRPC python stubs + conversion helpers
src/raspicat_async_vla_remote/    # gRPC server (Plan 1: dummy; Plan 2: real model)
src/raspicat_async_vla_edge/      # Edge ROS2 nodes (lifecycle, follower)
src/raspicat_async_vla_bringup/   # Launch composition
```

## Build

```bash
source /opt/ros/humble/setup.bash
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install
source install/setup.bash
```
