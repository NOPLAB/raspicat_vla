"""Launch the VLA edge lifecycle node (auto-transitions to active).

Optional launch args (override edge_params.yaml):
  remote_address  - gRPC server address (default: from yaml, typically localhost:50051)
  adapter_kind    - stub|asyncvla|omnivla
  image_topic     - camera image topic (default: /camera/image_raw; raspicat_sim uses /camera/color/image_raw)
  camera_device   - v4l2 device path (e.g. /dev/video0); when set, a v4l2_camera
                    node is launched and remapped to publish on image_topic.
                    Empty (default) = no camera node (frames come from elsewhere).
  with_follower   - true|false (also bring up path_follower_node)
  cmd_vel_topic   - follower's Twist output topic (default: /cmd_vel; set to a
                    non-motor topic like /cmd_vel_vla to run without driving the robot)
  asyncvla_weights_path / asyncvla_resume_step / asyncvla_device

Use cases:
  ros2 launch raspicat_vla_bringup edge_only.launch.py            # yaml defaults
  ros2 launch raspicat_vla_bringup edge_only.launch.py \\
      remote_address:=192.168.1.2:50051 adapter_kind:=asyncvla with_follower:=true
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, EmitEvent, RegisterEventHandler
from launch.conditions import IfCondition
from launch.event_handlers import OnProcessStart
from launch.events import matches_action
from launch.substitutions import LaunchConfiguration, PythonExpression
from launch_ros.actions import LifecycleNode, Node
from launch_ros.event_handlers import OnStateTransition
from launch_ros.events.lifecycle import ChangeState
from lifecycle_msgs.msg import Transition


def generate_launch_description():
    remote_address = LaunchConfiguration('remote_address')
    adapter_kind = LaunchConfiguration('adapter_kind')
    image_topic = LaunchConfiguration('image_topic')
    camera_device = LaunchConfiguration('camera_device')
    with_follower = LaunchConfiguration('with_follower')
    cmd_vel_topic = LaunchConfiguration('cmd_vel_topic')
    asyncvla_weights_path = LaunchConfiguration('asyncvla_weights_path')
    asyncvla_resume_step = LaunchConfiguration('asyncvla_resume_step')
    asyncvla_device = LaunchConfiguration('asyncvla_device')

    config = os.path.join(
        get_package_share_directory('raspicat_vla_edge'),
        'config', 'edge_params.yaml',
    )

    # Per-launch parameter overrides; only emit the ones that were set explicitly
    # (default '' means "leave the YAML value alone").
    overrides = {
        'remote_address': remote_address,
        'adapter_kind': adapter_kind,
        'image_topic': image_topic,
        'asyncvla_weights_path': asyncvla_weights_path,
        'asyncvla_resume_step': asyncvla_resume_step,
        'asyncvla_device': asyncvla_device,
    }

    edge = LifecycleNode(
        package='raspicat_vla_edge',
        executable='vla_edge_node',
        name='vla_edge_node',
        namespace='',
        output='screen',
        parameters=[config, overrides],
    )
    configure = EmitEvent(event=ChangeState(
        lifecycle_node_matcher=matches_action(edge),
        transition_id=Transition.TRANSITION_CONFIGURE,
    ))
    activate = EmitEvent(event=ChangeState(
        lifecycle_node_matcher=matches_action(edge),
        transition_id=Transition.TRANSITION_ACTIVATE,
    ))
    on_started = RegisterEventHandler(
        OnProcessStart(target_action=edge, on_start=[configure]),
    )
    on_inactive = RegisterEventHandler(
        OnStateTransition(
            target_lifecycle_node=edge,
            goal_state='inactive',
            entities=[activate],
        ),
    )

    follower = Node(
        package='raspicat_vla_edge',
        executable='path_follower_node',
        name='path_follower_node',
        output='screen',
        parameters=[{
            'lookahead': 0.4, 'max_v': 0.4, 'max_w': 1.0, 'rate_hz': 20.0,
            'cmd_vel_topic': cmd_vel_topic,
        }],
        condition=IfCondition(with_follower),
    )

    # Optional v4l2 camera driver. Only launched when camera_device is non-empty;
    # publishes raw sensor_msgs/Image on image_topic (v4l2_camera's own default
    # output is 'image_raw', remapped here to the edge node's image_topic).
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
        DeclareLaunchArgument('remote_address', default_value='localhost:50051'),
        DeclareLaunchArgument('adapter_kind', default_value='stub'),
        DeclareLaunchArgument('image_topic', default_value='/camera/image_raw'),
        DeclareLaunchArgument('camera_device', default_value=''),
        DeclareLaunchArgument('with_follower', default_value='false'),
        DeclareLaunchArgument('cmd_vel_topic', default_value='/cmd_vel'),
        DeclareLaunchArgument('asyncvla_weights_path', default_value='/workspace/models/AsyncVLA_release'),
        DeclareLaunchArgument('asyncvla_resume_step', default_value='750000'),
        DeclareLaunchArgument('asyncvla_device', default_value='cpu'),
        edge,
        on_started,
        on_inactive,
        follower,
        camera,
    ])
