"""Launch the edge stack in *cmd_vel preview* mode — no real robot control.

This is the edge half of ``run.sh run MODEL --mode cmd_vel``: it brings up the
VLA edge lifecycle node + path_follower_node exactly like ``edge_only.launch.py``
with a remote server, but the follower publishes its Twist to a **non-motor
topic** (default ``/cmd_vel_vla``) instead of ``/cmd_vel``. So the full
observation -> gRPC -> embedding -> path -> cmd_vel pipeline runs and the command
is observable (``ros2 topic echo /cmd_vel_vla``), yet the robot's motors — which
listen on ``/cmd_vel`` — are never driven.

The remote VLA server is started as a separate container by ``run.sh`` (the
remote images have no ROS2); this launch only points ``remote_address`` at it.

Launch args:
  remote_address  - gRPC server address (default: localhost:50051)
  adapter_kind    - stub|asyncvla|omnivla
  image_topic     - camera image topic (default: /camera/image_raw)
  cmd_vel_topic   - follower output topic (default: /cmd_vel_vla, a non-motor topic)
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    edge_launch = os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'launch', 'edge_only.launch.py',
    )

    return LaunchDescription([
        DeclareLaunchArgument('remote_address', default_value='localhost:50051'),
        DeclareLaunchArgument('adapter_kind', default_value='stub'),
        DeclareLaunchArgument('image_topic', default_value='/camera/image_raw'),
        # Default to a non-motor topic so the real robot is never driven.
        DeclareLaunchArgument('cmd_vel_topic', default_value='/cmd_vel_vla'),
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(edge_launch),
            launch_arguments={
                'remote_address': LaunchConfiguration('remote_address'),
                'adapter_kind': LaunchConfiguration('adapter_kind'),
                'image_topic': LaunchConfiguration('image_topic'),
                'with_follower': 'true',
                'cmd_vel_topic': LaunchConfiguration('cmd_vel_topic'),
            }.items(),
        ),
    ])
