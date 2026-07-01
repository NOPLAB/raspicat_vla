"""Launch the OmniVLA-edge MVP (Plan 2B Path 2 — policy runs ON the edge):
 - vla_edge_node       (lifecycle; adapter_kind=omnivla_edge_local, standalone)
 - path_follower_node  (Path -> /cmd_vel)

The full OmniVLA-edge policy + CLIP run locally in the edge node, which operates
in *standalone* mode: no cloud, no gRPC client, no embedding cache. The action
loop drives the local policy directly from the camera frame + goal. (Contrast
with mvp_omnivla.launch.py, Path 1, where a GPU cloud runs OmniVLA-original.)

Requirements: a CUDA-capable edge (the vendored OmniVLA_edge forward pass is
GPU-only) and the omnivla-edge weights at ``omnivla_edge_weights_path``
(``scripts/download_omnivla_checkpoints.sh edge``).

Inputs: publish RGB frames on the edge node's ``image_topic`` and a GoalSpec on
``goal_topic`` (text goals are the cleanest — see the adapter docstring).
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, ExecuteProcess, RegisterEventHandler, TimerAction,
)
from launch.conditions import LaunchConfigurationEquals
from launch.event_handlers import OnProcessExit, OnProcessStart
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LifecycleNode, Node


def generate_launch_description():
    weights_path = LaunchConfiguration('weights_path')
    device = LaunchConfiguration('device')
    image_topic = LaunchConfiguration('image_topic')
    camera_device = LaunchConfiguration('camera_device')

    edge_config = os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'config', 'edge_params.yaml',
    )

    edge = LifecycleNode(
        package='raspicat_vla_edge',
        executable='vla_edge_node',
        name='vla_edge_node',
        namespace='',
        output='screen',
        parameters=[edge_config, {
            'adapter_kind': 'omnivla_edge_local',
            'omnivla_edge_weights_path': weights_path,
            'omnivla_edge_device': device,
            'image_topic': image_topic,
        }],
    )
    node_name = '/vla_edge_node'
    configure_cmd = ExecuteProcess(
        cmd=['ros2', 'lifecycle', 'set', node_name, 'configure'],
        output='screen',
    )
    activate_cmd = ExecuteProcess(
        cmd=['ros2', 'lifecycle', 'set', node_name, 'activate'],
        output='screen',
    )

    follower = Node(
        package='raspicat_vla_edge',
        executable='path_follower_node',
        name='path_follower_node',
        output='screen',
        parameters=[{
            'max_v': 0.4, 'max_w': 1.0, 'rate_hz': 20.0,
        }],
    )

    # Optional camera driver (see edge_only.launch.py), selected by camera_kind.
    # Both variants publish raw frames on image_topic.
    camera_v4l2 = Node(
        package='v4l2_camera',
        executable='v4l2_camera_node',
        name='camera',
        output='screen',
        parameters=[{'video_device': camera_device}],
        remappings=[('image_raw', image_topic)],
        condition=LaunchConfigurationEquals('camera_kind', 'v4l2'),
    )
    camera_realsense = Node(
        package='realsense2_camera',
        executable='realsense2_camera_node',
        name='camera',
        namespace='',
        output='screen',
        remappings=[('color/image_raw', image_topic)],
        condition=LaunchConfigurationEquals('camera_kind', 'realsense'),
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            'weights_path',
            default_value='/workspace/models/omnivla-edge/omnivla-edge.pth'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        DeclareLaunchArgument('image_topic', default_value='/camera/image_raw'),
        DeclareLaunchArgument('camera_kind', default_value=''),
        DeclareLaunchArgument('camera_device', default_value=''),
        edge,
        # Drive the lifecycle via `ros2 lifecycle set`: launch_ros's
        # EmitEvent(ChangeState) was silently dropped on slow hosts (Jetson),
        # leaving the node stuck 'unconfigured'. configure runs a few seconds
        # after start; activate runs once configure exits (node is 'inactive').
        RegisterEventHandler(OnProcessStart(
            target_action=edge,
            on_start=[TimerAction(period=4.0, actions=[configure_cmd])],
        )),
        RegisterEventHandler(OnProcessExit(
            target_action=configure_cmd, on_exit=[activate_cmd],
        )),
        follower,
        camera_v4l2,
        camera_realsense,
    ])
