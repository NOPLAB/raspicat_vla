"""Launch the VLA edge lifecycle node (auto-transitions to active).

Optional launch args (override edge_params.yaml):
  remote_address  - gRPC server address (default: from yaml, typically localhost:50051)
  adapter_kind    - stub|asyncvla|omnivla
  image_topic     - camera image topic (default: /camera/image_raw; raspicat_sim uses /camera/color/image_raw)
  camera_kind     - ''|v4l2|realsense. Empty (default) = no camera node (frames
                    come from elsewhere). v4l2 launches a v4l2_camera node on
                    camera_device; realsense launches a realsense2_camera node.
                    Either is remapped to publish on image_topic.
  camera_device   - v4l2 device path (e.g. /dev/video0); only used when
                    camera_kind=v4l2.
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
from launch.actions import DeclareLaunchArgument, ExecuteProcess, RegisterEventHandler, TimerAction
from launch.conditions import IfCondition, LaunchConfigurationEquals
from launch.event_handlers import OnProcessExit, OnProcessStart
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LifecycleNode, Node


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
    # Drive the lifecycle transitions by shelling out to `ros2 lifecycle set`.
    # launch_ros's EmitEvent(ChangeState) proved unreliable on slow hosts
    # (Jetson): the event was silently dropped and the node stayed
    # 'unconfigured' even with a startup delay, whereas an explicit
    # `ros2 lifecycle set` always succeeded. configure runs a few seconds after
    # the process starts (so its change_state service is up); activate runs once
    # the configure process exits (i.e. the node has reached 'inactive').
    node_name = '/vla_edge_node'
    configure_cmd = ExecuteProcess(
        cmd=['ros2', 'lifecycle', 'set', node_name, 'configure'],
        output='screen',
    )
    activate_cmd = ExecuteProcess(
        cmd=['ros2', 'lifecycle', 'set', node_name, 'activate'],
        output='screen',
    )
    on_started = RegisterEventHandler(
        OnProcessStart(
            target_action=edge,
            on_start=[TimerAction(period=4.0, actions=[configure_cmd])],
        ),
    )
    on_configured = RegisterEventHandler(
        OnProcessExit(target_action=configure_cmd, on_exit=[activate_cmd]),
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

    # Optional camera driver, selected by camera_kind (empty = none). Both
    # variants are remapped to publish raw sensor_msgs/Image on image_topic.
    #  - v4l2:      generic UVC/USB webcam on camera_device (output 'image_raw').
    #  - realsense: Intel RealSense; realsense2_camera prefixes its topics with the
    #               node name, so the color stream is published on the fully
    #               qualified '/camera/color/image_raw' (NOT the relative
    #               'color/image_raw' — a relative remap FROM expands under the
    #               '' namespace to '/color/image_raw' and silently never matches).
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
        remappings=[('/camera/color/image_raw', image_topic)],
        condition=LaunchConfigurationEquals('camera_kind', 'realsense'),
    )

    return LaunchDescription([
        DeclareLaunchArgument('remote_address', default_value='localhost:50051'),
        DeclareLaunchArgument('adapter_kind', default_value='stub'),
        DeclareLaunchArgument('image_topic', default_value='/camera/image_raw'),
        DeclareLaunchArgument('camera_kind', default_value=''),
        DeclareLaunchArgument('camera_device', default_value=''),
        DeclareLaunchArgument('with_follower', default_value='false'),
        DeclareLaunchArgument('cmd_vel_topic', default_value='/cmd_vel'),
        DeclareLaunchArgument('asyncvla_weights_path', default_value='/workspace/models/AsyncVLA_release'),
        DeclareLaunchArgument('asyncvla_resume_step', default_value='750000'),
        DeclareLaunchArgument('asyncvla_device', default_value='cpu'),
        edge,
        on_started,
        on_configured,
        follower,
        camera_v4l2,
        camera_realsense,
    ])
