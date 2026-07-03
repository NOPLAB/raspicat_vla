"""Launch the OmniVLA real stack (Plan 2B Path 1):
 - OmniVLA cloud server  (--backend omnivla, GPU; loads omnivla-original)
 - vla_edge_node         (lifecycle; adapter_kind=omnivla)
 - path_follower_node    (Path -> /cmd_vel)

Cloud and edge can run on different hosts; this launch file assumes both
are on localhost. For split-host deployment, run the OmniVLA server in
Dockerfile.omnivla on the GPU box and bring up only the edge + follower
on the raspicat (use ``edge_only.launch.py`` and point ``remote_address``
at the cloud).
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

    omnivla_server = vla_server_process(
        backend='omnivla',
        port=grpc_port,
        extra_args=[
            '--vla-path', vla_path,
            '--resume-step', resume_step,
            '--device', device,
        ],
    )

    edge_actions = edge_lifecycle_actions(parameters=[edge_params_path(), {
        'remote_address': ['localhost:', grpc_port],
        'adapter_kind': 'omnivla',
    }])

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument('vla_path', default_value='/workspace/models/omnivla-original'),
        DeclareLaunchArgument('resume_step', default_value='120000'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        omnivla_server,
        *edge_actions,
        follower_node(),
    ])
