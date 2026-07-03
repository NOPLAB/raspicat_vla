"""Shared launch-file building blocks for the VLA edge stack.

Every bringup variant (dummy / asyncvla / omnivla / omnivla_edge_*) launches the
same three-piece skeleton: the edge LifecycleNode driven through
configure -> activate, a path_follower_node, and optionally a camera driver.
The helpers here keep that skeleton in one place; the per-variant launch files
contribute only their server process and parameter overrides.

Only imported by launch files (needs the ``launch`` / ``launch_ros`` runtime),
so keep the node modules free of imports from here.
"""
from __future__ import annotations

import os

from ament_index_python.packages import get_package_share_directory
from launch.actions import ExecuteProcess, RegisterEventHandler, TimerAction
from launch.conditions import LaunchConfigurationEquals
from launch.event_handlers import OnProcessExit, OnProcessStart
from launch_ros.actions import LifecycleNode, Node


def edge_params_path() -> str:
    """Absolute path to the edge node's default parameter YAML."""
    return os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'config', 'edge_params.yaml',
    )


def edge_lifecycle_actions(*, parameters, configure_delay_sec: float = 4.0) -> list:
    """The edge LifecycleNode plus the actions that drive it to 'active'.

    Returns a list of launch actions to splice into a LaunchDescription.

    Drives the lifecycle transitions by shelling out to ``ros2 lifecycle set``:
    launch_ros's EmitEvent(ChangeState) proved unreliable on slow hosts
    (Jetson) — the event was silently dropped and the node stayed
    'unconfigured' even with a startup delay, whereas an explicit
    ``ros2 lifecycle set`` always succeeded. configure runs a few seconds after
    the process starts (so its change_state service is up); activate runs once
    the configure process exits (i.e. the node has reached 'inactive').

    Each transition is retried in a loop: a one-shot ``ros2 lifecycle set``
    dies with "Node not found" until the CLI's discovery sees the node, and on
    a Jetson that lag can exceed any fixed configure_delay_sec — observed >4 s
    on an AGX Orin, leaving the edge unconfigured forever.
    """
    edge = LifecycleNode(
        package='raspicat_vla_edge',
        executable='vla_edge_node',
        name='vla_edge_node',
        namespace='',
        output='screen',
        parameters=parameters,
    )

    def _lifecycle_set_retrying(transition: str, *, attempts: int = 30) -> ExecuteProcess:
        return ExecuteProcess(
            cmd=['bash', '-c',
                 f'for i in $(seq {attempts}); do '
                 f'ros2 lifecycle set /vla_edge_node {transition} && exit 0; '
                 f'echo "retrying edge {transition} ($i/{attempts})"; sleep 2; done; '
                 f'echo "edge {transition} FAILED after {attempts} attempts" >&2; exit 1'],
            output='screen',
        )

    configure_cmd = _lifecycle_set_retrying('configure')
    activate_cmd = _lifecycle_set_retrying('activate')
    return [
        edge,
        RegisterEventHandler(OnProcessStart(
            target_action=edge,
            on_start=[TimerAction(period=configure_delay_sec, actions=[configure_cmd])],
        )),
        RegisterEventHandler(OnProcessExit(
            target_action=configure_cmd, on_exit=[activate_cmd],
        )),
    ]


def follower_node(*, condition=None, **params) -> Node:
    """path_follower_node with the stack-default limits; ``params`` overrides."""
    parameters = {'max_v': 0.4, 'max_w': 1.0, 'rate_hz': 20.0}
    parameters.update(params)
    return Node(
        package='raspicat_vla_edge',
        executable='path_follower_node',
        name='path_follower_node',
        output='screen',
        parameters=[parameters],
        condition=condition,
    )


def camera_nodes(*, image_topic, camera_device) -> list:
    """Optional camera drivers, selected by the ``camera_kind`` launch config.

    Empty camera_kind (the default) starts neither node. Both variants are
    remapped to publish raw sensor_msgs/Image on ``image_topic``:
     - v4l2:      generic UVC/USB webcam on camera_device (output 'image_raw').
     - realsense: Intel RealSense; realsense2_camera prefixes its topics with the
                  node name, so the color stream is published on the fully
                  qualified '/camera/color/image_raw' (NOT the relative
                  'color/image_raw' — a relative remap FROM expands under the
                  '' namespace to '/color/image_raw' and silently never matches).
    """
    return [
        Node(
            package='v4l2_camera',
            executable='v4l2_camera_node',
            name='camera',
            output='screen',
            parameters=[{'video_device': camera_device}],
            remappings=[('image_raw', image_topic)],
            condition=LaunchConfigurationEquals('camera_kind', 'v4l2'),
        ),
        Node(
            package='realsense2_camera',
            executable='realsense2_camera_node',
            name='camera',
            namespace='',
            output='screen',
            remappings=[('/camera/color/image_raw', image_topic)],
            condition=LaunchConfigurationEquals('camera_kind', 'realsense'),
        ),
    ]


def vla_server_process(*, backend: str, port, extra_args=()) -> ExecuteProcess:
    """A raspicat_vla_remote server process for the given backend."""
    return ExecuteProcess(
        cmd=[
            'python3', '-m', 'raspicat_vla_remote.server_main',
            '--backend', backend,
            '--port', port,
            *extra_args,
        ],
        output='screen',
    )
