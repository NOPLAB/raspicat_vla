"""Launch the AsyncVLA real stack (Plan 2A):
 - AsyncVLA cloud server  (--backend asyncvla, GPU; loads AsyncVLA_release)
 - vla_edge_node          (lifecycle; adapter_kind=asyncvla, runs Edge_adapter)
 - path_follower_node     (Path -> /cmd_vel)

The cloud runs the heavy backbone (~7.5 B params) on GPU and emits a
(8, 1024) projected_actions tensor; the edge runs a small ~5 M-param
Edge_adapter (efficientnet-b0 + transformer decoder) over (cur, past, vla_feature),
applies delta_to_pose, and publishes a nav_msgs/Path.

For split-host deployment, run the cloud in Dockerfile.asyncvla on a GPU
box and point the edge's remote_address at it. Both hosts need
external/MBRA on PYTHONPATH (Edge_adapter's transitive dep).
"""
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration

from raspicat_vla_edge.launch_util import (
    edge_lifecycle_actions, edge_params_path, follower_node, vla_server_process,
)


def generate_launch_description():
    grpc_port = LaunchConfiguration('grpc_port')
    vla_path = LaunchConfiguration('vla_path')
    resume_step = LaunchConfiguration('resume_step')
    device = LaunchConfiguration('device')
    edge_device = LaunchConfiguration('edge_device')

    asyncvla_server = vla_server_process(
        backend='asyncvla',
        port=grpc_port,
        extra_args=[
            '--vla-path', vla_path,
            '--resume-step', resume_step,
            '--device', device,
        ],
    )

    edge_actions = edge_lifecycle_actions(parameters=[edge_params_path(), {
        'remote_address': ['localhost:', grpc_port],
        'adapter_kind': 'asyncvla',
        'asyncvla_weights_path': vla_path,
        'asyncvla_resume_step': resume_step,
        'asyncvla_device': edge_device,
    }])

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument('vla_path', default_value='/workspace/models/AsyncVLA_release'),
        DeclareLaunchArgument('resume_step', default_value='750000'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        DeclareLaunchArgument('edge_device', default_value='cpu'),
        asyncvla_server,
        *edge_actions,
        follower_node(),
    ])
