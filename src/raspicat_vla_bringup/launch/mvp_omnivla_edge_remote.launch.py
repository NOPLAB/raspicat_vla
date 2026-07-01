"""Launch the OmniVLA-edge *remote-split* MVP (Plan 2B Path 3):
 - OmniVLA-edge server   (--backend omnivla_edge, GPU; loads omnivla-edge.pth)
 - vla_edge_node         (lifecycle; adapter_kind=omnivla, path-only)
 - path_follower_node    (Path -> /cmd_vel)

The OmniVLA-edge policy runs on a remote GPU box (typically a Jetson) and streams
predicted waypoints over gRPC; the edge runs only the light path-only adapter and
does the control. This mirrors the intended deployment ("Jetson infers, Raspberry
Pi controls") but assumes both are on localhost. For a real split-host run, start
the server with ``scripts/vla.sh run omnivla_edge --remote --gpu`` on the Jetson
and bring up only the edge with ``edge_only.launch.py`` (adapter_kind:=omnivla)
pointed at the Jetson.

Contrast:
 - mvp_omnivla_edge.launch.py (Path 2): the SAME policy runs ON the edge,
   standalone (no cloud).
 - mvp_omnivla.launch.py (Path 1): a cloud runs OmniVLA-*original*.

Requires the omnivla-edge weights at ``weights_path``
(``scripts/download_omnivla_edge_checkpoints.sh``) and a CUDA server host.
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, EmitEvent, ExecuteProcess, RegisterEventHandler,
)
from launch.event_handlers import OnProcessStart
from launch.events import matches_action
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LifecycleNode, Node
from launch_ros.event_handlers import OnStateTransition
from launch_ros.events.lifecycle import ChangeState
from lifecycle_msgs.msg import Transition


def generate_launch_description():
    grpc_port = LaunchConfiguration('grpc_port')
    weights_path = LaunchConfiguration('weights_path')
    device = LaunchConfiguration('device')

    edge_config = os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'config', 'edge_params.yaml',
    )

    edge_server = ExecuteProcess(
        cmd=[
            'python3', '-m', 'raspicat_vla_remote.server_main',
            '--backend', 'omnivla_edge',
            '--port', grpc_port,
            '--vla-path', weights_path,
            '--device', device,
        ],
        output='screen',
    )

    edge = LifecycleNode(
        package='raspicat_vla_edge',
        executable='vla_edge_node',
        name='vla_edge_node',
        namespace='',
        output='screen',
        parameters=[edge_config, {
            'remote_address': ['localhost:', grpc_port],
            'adapter_kind': 'omnivla',
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

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument(
            'weights_path',
            default_value='/workspace/models/omnivla-edge/omnivla-edge.pth'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        edge_server,
        edge,
        RegisterEventHandler(OnProcessStart(target_action=edge, on_start=[configure])),
        RegisterEventHandler(OnStateTransition(
            target_lifecycle_node=edge, goal_state='inactive', entities=[activate],
        )),
        follower,
    ])
