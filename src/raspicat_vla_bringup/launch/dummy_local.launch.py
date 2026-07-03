"""Launch the full Plan-1 MVP locally:
 - vla_dummy_server      (gRPC, deterministic embeddings)
 - vla_edge_node         (lifecycle, configured + activated)
 - path_follower_node    (Path -> /cmd_vel)
"""
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.substitutions import LaunchConfiguration

from raspicat_vla_edge.launch_util import (
    edge_lifecycle_actions, edge_params_path, follower_node,
)


def generate_launch_description():
    grpc_port = LaunchConfiguration('grpc_port')
    inference_ms = LaunchConfiguration('inference_ms')

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

    edge_actions = edge_lifecycle_actions(parameters=[edge_params_path(), {
        'remote_address': ['localhost:', grpc_port],
    }])

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument('inference_ms', default_value='50.0'),
        dummy_server,
        *edge_actions,
        follower_node(),
    ])
