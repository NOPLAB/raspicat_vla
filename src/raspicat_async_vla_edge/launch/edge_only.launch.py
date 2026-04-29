"""Launch the AsyncVLA edge lifecycle node (auto-transitions to active)."""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import EmitEvent, RegisterEventHandler
from launch.event_handlers import OnProcessStart
from launch.events import matches_action
from launch_ros.actions import LifecycleNode
from launch_ros.event_handlers import OnStateTransition
from launch_ros.events.lifecycle import ChangeState
from lifecycle_msgs.msg import Transition


def generate_launch_description():
    config = os.path.join(
        get_package_share_directory('raspicat_async_vla_edge'),
        'config', 'edge_params.yaml',
    )
    edge = LifecycleNode(
        package='raspicat_async_vla_edge',
        executable='asyncvla_edge_node',
        name='asyncvla_edge_node',
        namespace='',
        output='screen',
        parameters=[config],
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
    return LaunchDescription([edge, on_started, on_inactive])
