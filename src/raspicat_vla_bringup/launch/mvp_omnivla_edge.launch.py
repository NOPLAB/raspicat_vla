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
    DeclareLaunchArgument, EmitEvent, RegisterEventHandler,
)
from launch.conditions import IfCondition
from launch.event_handlers import OnProcessStart
from launch.events import matches_action
from launch.substitutions import LaunchConfiguration, PythonExpression
from launch_ros.actions import LifecycleNode, Node
from launch_ros.event_handlers import OnStateTransition
from launch_ros.events.lifecycle import ChangeState
from lifecycle_msgs.msg import Transition


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
    configure = EmitEvent(event=ChangeState(
        lifecycle_node_matcher=matches_action(edge),
        transition_id=Transition.TRANSITION_CONFIGURE,
    ))
    activate = EmitEvent(event=ChangeState(
        lifecycle_node_matcher=matches_action(edge),
        transition_id=Transition.TRANSITION_ACTIVATE,
    ))

    follower = Node(
        package='raspicat_vla_edge',
        executable='path_follower_node',
        name='path_follower_node',
        output='screen',
        parameters=[{
            'lookahead': 0.4, 'max_v': 0.4, 'max_w': 1.0, 'rate_hz': 20.0,
        }],
    )

    # Optional v4l2 camera driver (see edge_only.launch.py). Only launched when
    # camera_device is non-empty; publishes raw frames on image_topic.
    camera = Node(
        package='v4l2_camera',
        executable='v4l2_camera_node',
        name='camera',
        output='screen',
        parameters=[{'video_device': camera_device}],
        remappings=[('image_raw', image_topic)],
        condition=IfCondition(PythonExpression(["'", camera_device, "' != ''"])),
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            'weights_path',
            default_value='/workspace/models/omnivla-edge/omnivla-edge.pth'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        DeclareLaunchArgument('image_topic', default_value='/camera/image_raw'),
        DeclareLaunchArgument('camera_device', default_value=''),
        edge,
        RegisterEventHandler(OnProcessStart(target_action=edge, on_start=[configure])),
        RegisterEventHandler(OnStateTransition(
            target_lifecycle_node=edge, goal_state='inactive', entities=[activate],
        )),
        follower,
        camera,
    ])
