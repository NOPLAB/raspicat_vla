"""Launch the full Plan-1 MVP locally:
 - vla_dummy_server      (gRPC, deterministic embeddings)
 - vla_edge_node         (lifecycle, configured + activated)
 - path_follower_node    (Path -> /cmd_vel)
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, ExecuteProcess, RegisterEventHandler,
    TimerAction,
)
from launch.event_handlers import OnProcessExit, OnProcessStart
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LifecycleNode, Node


def generate_launch_description():
    grpc_port = LaunchConfiguration('grpc_port')
    inference_ms = LaunchConfiguration('inference_ms')

    edge_config = os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'config', 'edge_params.yaml',
    )

    dummy_server = ExecuteProcess(
        cmd=[
            'ros2', 'run', 'raspicat_vla_remote', 'vla_dummy_server',
            '--port', grpc_port,
            '--inference-ms', inference_ms,
            '--num-tokens', '8',
            '--embed-dim', '1024',
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
            'lookahead': 0.4, 'max_v': 0.4, 'max_w': 1.0, 'rate_hz': 20.0,
        }],
    )

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument('inference_ms', default_value='50.0'),
        dummy_server,
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
    ])
