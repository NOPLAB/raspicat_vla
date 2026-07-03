"""Launch the OmniVLA-edge *remote-split* stack (Plan 2B Path 3):
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
 - omnivla_edge_local.launch.py (Path 2): the SAME policy runs ON the edge,
   standalone (no cloud).
 - omnivla.launch.py (Path 1): a cloud runs OmniVLA-*original*.

Requires the omnivla-edge weights at ``weights_path``
(``scripts/download_omnivla_edge_checkpoints.sh``) and a CUDA server host.
"""
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration

from raspicat_vla_edge.launch_util import (
    edge_lifecycle_actions, edge_params_path, follower_node, vla_server_process,
)


def generate_launch_description():
    grpc_port = LaunchConfiguration('grpc_port')
    weights_path = LaunchConfiguration('weights_path')
    device = LaunchConfiguration('device')

    edge_server = vla_server_process(
        backend='omnivla_edge',
        port=grpc_port,
        extra_args=[
            '--vla-path', weights_path,
            '--device', device,
        ],
    )

    edge_actions = edge_lifecycle_actions(parameters=[edge_params_path(), {
        'remote_address': ['localhost:', grpc_port],
        'adapter_kind': 'omnivla',
    }])

    return LaunchDescription([
        DeclareLaunchArgument('grpc_port', default_value='50051'),
        DeclareLaunchArgument(
            'weights_path',
            default_value='/workspace/models/omnivla-edge/omnivla-edge.pth'),
        DeclareLaunchArgument('device', default_value='cuda:0'),
        edge_server,
        *edge_actions,
        follower_node(),
    ])
