---
title: ROS 2 学习笔记：从通信机制到机械臂项目实践
tags:
  - ROS2
  - 机器人
  - MoveIt2
  - Jazzy
  - CoppeliaSim
---

# ROS 2 学习笔记：从通信机制到机械臂项目实践

> 适用环境：Ubuntu 24.04、ROS 2 Jazzy、Python（`rclpy`）、C++（`rclcpp`）。  
> 学习目标：理解 ROS 2 如何把感知、规划、控制和仿真连接起来，并能独立排查机械臂项目的通信问题。  
> 本笔记面向正在使用 **CoppeliaSim + ROS 2 + MoveIt 2 + IRB140** 的学习者，实例中的部分话题名称来自该项目，并非 ROS 2 的通用默认名称。

## 1. 一句话理解 ROS 2

**ROS 2（Robot Operating System 2）不是操作系统，而是机器人软件开发框架和通信生态。** 它提供节点间通信、接口定义、工具、启动与部署机制，让不同程序能够协同工作。

例如一个机械臂系统：

```text
RViz（交互式目标）
        │
        ▼
MoveIt 2（运动规划）
        │  FollowJointTrajectory Action
        ▼
ROS 2 轨迹执行后端
        │  ZeroMQ Remote API（外部接口，不属于 ROS 2 本身）
        ▼
CoppeliaSim（机械臂仿真）
        │
        └── 实际关节角度 → ROS 2 JointState → RViz / MoveIt 2
```

### 1.1 ROS 2 负责什么、不负责什么？

| 能力 | ROS 2 本身是否提供 | 常见实现 |
|---|---|---|
| 节点之间传输数据 | 是 | Topic / Service / Action |
| 时间、参数、日志、启动管理 | 是 | `rclpy`、`ros2 launch` |
| 坐标系关系的发布与查询 | 生态组件 | `tf2` |
| 机器人关节、连杆模型 | 生态规范及组件 | URDF、`robot_state_publisher` |
| 运动路径规划 | 不是 ROS 2 核心功能 | MoveIt 2 / OMPL |
| 机械臂物理仿真 | 否 | CoppeliaSim、Gazebo、MuJoCo |
| 深度强化学习训练 | 否 | Gymnasium、Stable-Baselines3、PyTorch |

**记忆方式：ROS 2 解决“各模块如何协作”，规划器决定“怎么走”，控制器决定“如何执行”，仿真器提供“机器人和环境如何响应”。**

---

## 2. ROS 2 系统的基本组成

### 2.1 Node（节点）

**节点是一个承担特定功能的程序实体**。一个进程可以包含一个或多个节点，节点名称并不等于进程名称。

例如：

- `/move_group`：MoveIt 2 的规划和执行服务节点。
- `/robot_state_publisher`：根据 URDF 和关节状态发布连杆之间的 TF。
- `/coppeliasim_trajectory_backend`：项目中的轨迹执行和仿真状态读取节点（以实际节点名为准）。

查询当前系统：

```bash
ros2 node list
ros2 node info /move_group
```

### 2.2 Topic（话题）——持续的数据流

发布者（Publisher）不断发布消息，订阅者（Subscriber）接收。

```text
关节状态发布节点  ── /robot_arm/actual_joint_states ──► MoveIt / RViz
                   sensor_msgs/msg/JointState
```

典型用途：关节角度、相机图像、激光雷达、里程计。

```bash
ros2 topic list
ros2 topic list -t
ros2 topic info /robot_arm/actual_joint_states
ros2 topic info --verbose /robot_arm/actual_joint_states
ros2 topic echo --once /robot_arm/actual_joint_states
ros2 topic hz /robot_arm/actual_joint_states
ros2 interface show sensor_msgs/msg/JointState
```

`JointState` 的重要字段：

```yaml
name: [joint, joint_2, joint_3, joint_4, joint_5, joint_6]
position: [0.0, 0.0, 0.0, 0.0, -1.5708, 0.0]
velocity: []
effort: []
```

`position` 对旋转关节通常是 **rad（弧度）**，对移动关节通常是 **m（米）**。位置、速度与力矩数组若非空，必须与 `name` 的顺序一致。不能假设所有机器人都会按照 `joint_1`～`joint_6` 命名。

### 2.3 Service（服务）——一次请求与一次响应

服务适合“发出请求 → 等待结果”的短操作。

例如：请求安全停止：

```bash
ros2 service list
ros2 service type /robot_arm/safe_stop
ros2 service call /robot_arm/safe_stop std_srvs/srv/Trigger "{}"
```

但安全停止服务的具体行为由后端实现决定，不能把软件停止当作真实工业安全急停。

### 2.4 Action（动作）——需要时间执行的任务

Action 适合“发起目标 → 运行过程反馈 → 最终结果”，也支持取消。

机械臂最典型的 Action 是 `control_msgs/action/FollowJointTrajectory`。

```text
Action Client（MoveIt）
     │  发送：六关节轨迹及时间戳
     ▼
Action Server（轨迹后端）
     │  执行 + 反馈 + 取消
     ▼
CoppeliaSim
```

查看：

```bash
ros2 action list -t
ros2 action info /robot_arm/follow_joint_trajectory
ros2 interface show control_msgs/action/FollowJointTrajectory
```

重要区分：**Topic 没有内建“任务完成”的概念；Service 不适合长时间持续反馈；Action 专门表示可跟踪、可取消的长任务。**

### 2.5 Parameter（参数）

参数是节点的可配置值，例如运行频率、最大速度、场景名称等。

```bash
ros2 param list
ros2 param list /move_group
ros2 param get /move_group allow_trajectory_execution
ros2 param dump /move_group
```

不是所有配置都能在运行时修改：具体取决于节点是否允许动态参数更新。

### 2.6 Launch（启动文件）

一个机械臂系统通常需要同时启动很多节点。Launch 用于统一配置和启动。

```bash
ros2 launch irb140_moveit_config planning_only.launch.py
```

在本项目中，应区分：

- `planning_only.launch.py`：只规划，不启动实际轨迹控制链路。
- `coppeliasim_execution.launch.py`：面向仿真执行的启动入口，实际允许执行与否还取决于后端授权、仿真状态和配置。

**一个 Launch 文件能启动成功，不等于它启动的机器人可以安全执行轨迹。**

---

## 3. Topic、Service、Action 的选用

| 需求 | 最合适机制 | 原因 |
|---|---|---|
| 每秒发布关节位置 50 次 | Topic | 连续数据流 |
| 发送一次“查询/设置”并得到结果 | Service | 一次请求和响应 |
| 执行 5 秒运动并随时查看进度 | Action | 有目标、反馈、取消及结果 |
| 发布 TCP 的坐标变换 | TF / Topic | 持续发布空间关系 |
| 保存最大速度 | Parameter / YAML | 配置项 |

可以类比：

- Topic 像广播电台。
- Service 像一次问答。
- Action 像下达一项可查看进度、可取消的工作任务。

---

## 4. ROS 2 的通信底层：DDS 与 QoS

ROS 2 的节点通信通常通过 **DDS/RTPS** 实现。不同节点能自动发现彼此；消息的实际发布和订阅还受 **QoS（服务质量）** 配置影响。

QoS 常见维度：

- **Reliability**：`reliable` 或 `best_effort`。
- **Durability**：`volatile` 或 `transient_local`。
- **History/Depth**：保存多少条尚未消费的消息。

示例：高频相机图像有时使用 `best_effort`；需要刚加入的订阅者收到最新静态数据时，可能使用 `transient_local`。

**排错提示：话题名称存在，但 `ros2 topic echo` 没有数据，不一定是没有发布者，也可能是 QoS 不兼容。**

```bash
ros2 topic info --verbose /话题名
```

---

## 5. 工作空间、软件包和环境加载

### 5.1 Workspace（工作空间）

标准 colcon 工作空间常见结构：

```text
robot_arm_core_ws/
├── src/                 # 源码包
│   ├── irb140_description/
│   ├── irb140_moveit_config/
│   └── robot_arm_control_core/
├── build/               # 构建中间文件
├── install/             # 安装后可被 ROS 2 发现的内容
├── log/                 # 构建与测试日志
└── scripts/
```

### 5.2 构建与加载

一般 ROS 2 项目的标准流程是：

```bash
source /opt/ros/jazzy/setup.bash
cd ~/your_ros_ws
colcon build --symlink-install
source install/setup.bash
```

**针对当前 IRB140 项目，应优先使用已经验证的自定义构建脚本**，以保留 CoppeliaSim Python 虚拟环境解释器：

```bash
cd ~/robot_arm_core_ws
source /opt/ros/jazzy/setup.bash
./scripts/build_with_coppelia_venv.sh
source install/setup.bash
```

验证包是否被发现：

```bash
ros2 pkg list | grep irb140
ros2 pkg prefix irb140_moveit_config
```

如果 `ros2 pkg prefix` 提示找不到：优先检查包的 `package.xml`、构建报错以及是否执行了 `source install/setup.bash`。

### 5.3 Python 包与入口

ROS 2 Python 包通常由 `package.xml`、`setup.py`、`setup.cfg`、Python 模块和 `entry_points` 组成；构建后才能通过 `ros2 run 包名 可执行入口` 运行。

```bash
ros2 pkg executables robot_arm_control_core
ros2 run robot_arm_control_core <实际可执行入口>
```

**重要：** 激活 Python 虚拟环境不保证 ROS 2 已安装的 console script 使用该虚拟环境的 Python。若脚本第一行（shebang）指向 `/usr/bin/python3`，就可能无法导入虚拟环境中的 `zmq` 或 CoppeliaSim 客户端。

```bash
head -n 1 ~/robot_arm_core_ws/install/robot_arm_control_core/lib/robot_arm_control_core/coppeliasim_readonly_state_node
```

---

## 6. 自己动手：一个最简单的 ROS 2 Topic 示例

以下例子不需要机器人或 CoppeliaSim，只需要 ROS 2 Jazzy 和 `rclpy`。

**终端 A：创建发布者**

保存为 `talker.py`：

```python
import rclpy
from rclpy.node import Node
from std_msgs.msg import String

class Talker(Node):
    def __init__(self):
        super().__init__('my_talker')
        self.pub = self.create_publisher(String, '/hello_ros2', 10)
        self.count = 0
        self.timer = self.create_timer(1.0, self.publish_hello)

    def publish_hello(self):
        msg = String()
        msg.data = f'Hello ROS 2: {self.count}'
        self.pub.publish(msg)
        self.count += 1

def main():
    rclpy.init()
    node = Talker()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()
```

运行：

```bash
source /opt/ros/jazzy/setup.bash
python3 talker.py
```

**终端 B：订阅消息**

```bash
source /opt/ros/jazzy/setup.bash
ros2 topic echo /hello_ros2
```

应该能看到：

```yaml
data: 'Hello ROS 2: 0'
---
data: 'Hello ROS 2: 1'
```

进一步检查：

```bash
ros2 node list
ros2 topic hz /hello_ros2
ros2 topic info /hello_ros2
```

**理解练习：** `create_timer(1.0, ...)` 定义每秒调用一次的定时器；`publish()` 发布消息；`rclpy.spin()` 让节点持续处理回调。

---

## 7. 机器人坐标系与 TF2

机器人不能只靠关节角度工作，还必须知道**一个位置是相对于谁定义的**。

例如：

```text
world
  └── base_link
       └── link_1 ... link_6
                        └── tool0
```

- `world`：仿真世界参考坐标系。
- `base_link`：机器人基座参考坐标系。
- `tool0`：末端工具参考坐标系。

### 7.1 为什么要做 TF 变换？

CoppeliaSim 给出方块在世界系下的位置 \(\mathbf p_{world}\)，MoveIt 的规划可能使用机器人基座系。两者需要转换：

\[
{}^{base}T_{object} = ({}^{world}T_{base})^{-1}\,{}^{world}T_{object}
\]

其中 \(T\) 是包含旋转与平移的 **4×4 齐次变换矩阵**。

### 7.2 静态 TF 与动态 TF

- 静态 TF：如固定的 `world → base_link`，通常通过 `/tf_static` 发布。
- 动态 TF：如连杆随关节运动产生的关系，通常通过 `/tf` 发布。

查看 TF：

```bash
ros2 topic list | grep tf
ros2 run tf2_ros tf2_echo world base_link
```

如果生成的 URDF 已定义连杆关系，`robot_state_publisher` 会结合 `/joint_states` 输出机器人动态 TF。

**特别注意：** SRDF 的虚拟关节声明 `world` 和 `base_link` 的关系，但不等于自动确定了实际非零世界位姿。项目中的 `world → base_link` 应与 CoppeliaSim 的已验证变换一致，且不能重复叠加偏移。

---

## 8. URDF、SRDF、MoveIt 2 的关系

### 8.1 URDF：机器人的机械结构

描述：连杆（Link）、关节（Joint）、运动范围、视觉几何和碰撞几何。

### 8.2 SRDF：为运动规划补充语义

例如：

- 规划组：`arm`。
- 规划链：`base_link → tool0`。
- 预定义姿态：`home`。
- 经确认可以忽略的自碰撞连杆对。

### 8.3 MoveIt 2：在模型和约束下生成路径

典型处理流程：

```text
实际关节角度 JointState
        ↓
当前 Robot State + URDF / SRDF
        ↓
目标位姿或目标关节角度
        ↓
IK / 碰撞检查 / OMPL 规划
        ↓
JointTrajectory（轨迹点 + 时间戳）
        ↓
FollowJointTrajectory Action（执行后端）
```

**Plan 与 Execute 的区别：**

- `Plan`：计算出轨迹，并不代表仿真机械臂已经运动。
- `Execute`：将规划好的轨迹交给执行后端，并等待执行反馈。

当前项目里已验证了规划和受限单关节实际执行；较复杂的 MoveIt Execute、完整工作台避障与抓取需要按照其各自验收结果判断，不能仅凭界面“连接成功”推断全部完成。

### 8.4 机器人关节角度与 TCP 位姿

六个关节角：

\[
\mathbf q=[q_1,q_2,q_3,q_4,q_5,q_6]^\mathsf T
\]

正运动学：

\[
{}^{base}T_{tool}=FK(\mathbf q)
\]

逆运动学：已知目标 \(T_{tool}\)，求满足约束的 \(\mathbf q\)。

同一个末端目标位姿可能对应多组关节角；有时没有可行解。规划器还要检查路径中间状态，而不只是目标是否可达。

---

## 9. JointTrajectory 与执行反馈

一条轨迹不是只包含“终点”。它通常由多个轨迹点组成，每个点都带有时间信息。

例如概念性示意：

```yaml
joint_names: [joint, joint_2, joint_3, joint_4, joint_5, joint_6]
points:
  - positions: [0.0, 0.0, 0.0, 0.0, -1.5708, 0.0]
    time_from_start: 0.0s
  - positions: [0.04, 0.0, 0.0, 0.0, -1.5708, 0.0]
    time_from_start: 2.5s
  - positions: [0.0873, 0.0, 0.0, 0.0, -1.5708, 0.0]
    time_from_start: 5.0s
```

这只是便于理解的伪 YAML，不是可直接发送给 ROS Action 的完整消息格式。

执行后端要处理：

1. 轨迹关节名称与顺序。
2. 起点是否与实际关节位置一致。
3. 轨迹时间戳是否严格合理。
4. 速度、加速度、关节限位和碰撞约束。
5. 实际跟踪误差和执行超时。
6. 取消任务、异常停止和控制源冲突。

**误区：只看到机械臂“动了”，不等于它按规划轨迹正确执行。** 还应检查 Action 状态、末端误差及中间轨迹跟踪数据。

---

## 10. ROS 2 如何连接 CoppeliaSim？

在这个项目中，ROS 2 和 CoppeliaSim 之间通过 **ZMQ Remote API** 协作。这个 ZMQ 连接不是 ROS Topic；它是后端节点内部调用的仿真接口。

```text
ROS Action Goal
     ↓
后端节点验证与插值
     ↓
CoppeliaSim ZMQ Remote API
     ├── setJointTargetPosition（下发目标关节角）
     └── getJointPosition（读取实际关节角）
     ↓
发布 JointState → ROS 2 图中的其他节点
```

本项目有两套容易混淆的关节名称：

| CoppeliaSim 原生名称（示意） | MoveIt URDF 名称 |
|---|---|
| `IRB140_joint1` | `joint` |
| `IRB140_joint2` | `joint_2` |
| `IRB140_joint3` | `joint_3` |
| `IRB140_joint4` | `joint_4` |
| `IRB140_joint5` | `joint_5` |
| `IRB140_joint6` | `joint_6` |

需要使用**经过验证的固定名称映射**，不应在每次运行时自动计算新的 offset。

另外，当前另有独立的 SAC 强化学习工作空间。**不能让 ROS 轨迹后端和 SAC 环境同时向 CoppeliaSim 写入关节目标**，否则可能出现控制冲突。

---

## 11. ROS 2 与强化学习如何结合？

ROS 2 可以充当机器人软件层，但**强化学习训练本身不要求必须经过 ROS 2**。

目前的 IRB140 SAC 工程使用：

```text
Gymnasium 环境
       ↓
SAC（Stable-Baselines3）
       ↓
三维 TCP 动作 Δx, Δy, Δz
       ↓
Jacobian + 阻尼最小二乘（DLS）
       ↓
CoppeliaSim Remote API
       ↓
机器人和目标的实际状态 → 奖励 → SAC 更新
```

它可以直接调用 CoppeliaSim API，不必为了训练而强行绕经 MoveIt 2。

两种系统的区别：

| 比较点 | MoveIt 2 | SAC 强化学习 |
|---|---|---|
| 主要用途 | 利用模型与约束计算轨迹 | 通过经验和奖励学习策略 |
| 典型输入 | 当前状态、目标、碰撞场景 | Observation |
| 典型输出 | 带时间的关节轨迹 | 每一步的动作 |
| 是否需要训练 | 通常不需要 | 需要 |
| 如何判断成功 | 规划/执行结果及误差 | 独立任务成功条件 |

未来可将 MoveIt 轨迹用于专家示教数据采集，再训练行为克隆或 Diffusion Policy；但是生成示教数据还需要明确观测、动作、频率和任务标签的对应关系。

---

## 12. 高频排错清单

| 现象 | 优先检查 |
|---|---|
| `Package not found` | 是否构建、`package.xml` 是否有效、是否 `source install/setup.bash` |
| `ros2 run` 找不到入口 | `setup.py` 的 console_scripts、是否重建 |
| Python 导入 `zmq` 失败 | 入口脚本 shebang、构建时使用的 Python 解释器 |
| Topic 存在但没消息 | 发布者状态、QoS、节点是否被阻塞 |
| RViz 有机器人但不能 Plan | `/move_group`、规划组、目标状态、状态有效性、OMPL 日志 |
| Plan 成功但 Execute 无效 | Action Server、控制器映射、执行授权、`allow_trajectory_execution` |
| Action 目标被拒绝 | 查看后端拒绝原因：仿真状态、场景名称、限位、起点、授权 |
| RViz 姿态与 CoppeliaSim 不一致 | `/joint_states` 来源、TF、关节映射、offset、是否 FakeSystem |
| 机械臂突然跳动 | 是否直接写入位置、起点不一致、控制模式冲突 |
| 仿真中有两个程序抢控制 | 唯一控制源、后台节点、强化学习进程与 ROS 后端是否并行 |

### 12.1 实用诊断命令

```bash
# 发现节点、话题和 Action
ros2 node list
ros2 topic list -t
ros2 action list -t

# 确认关节反馈
ros2 topic echo --once /robot_arm/actual_joint_states
ros2 topic hz /robot_arm/actual_joint_states
ros2 topic info --verbose /robot_arm/actual_joint_states

# 查看轨迹接口
ros2 action info /robot_arm/follow_joint_trajectory
ros2 interface show control_msgs/action/FollowJointTrajectory

# 查看系统参数
ros2 param list /move_group

# 查看 TF
ros2 run tf2_ros tf2_echo world base_link
```

若 ROS 2 发现不了同机节点，还应检查终端是否使用相同的 `ROS_DOMAIN_ID`，以及相关 ROS 中间件和网络配置。



---

## 14. 核心术语速查

| 术语 | 中文 | 简短含义 |
|---|---|---|
| ROS 2 | 机器人软件框架 | 机器人模块协作基础 |
| Node | 节点 | 承担一个功能的计算单元 |
| Publisher | 发布者 | 向 Topic 发消息 |
| Subscriber | 订阅者 | 从 Topic 收消息 |
| Topic | 话题 | 持续的数据流 |
| Service | 服务 | 一次请求与响应 |
| Action | 动作 | 有过程反馈的长时间目标 |
| Message | 消息 | 结构化传输数据 |
| DDS | 数据分发服务 | ROS 2 常用通信中间件 |
| QoS | 服务质量 | 消息可靠性等配置 |
| TF2 | 坐标变换框架 | 管理坐标系关系 |
| URDF | 机器人描述格式 | 机器人结构与关节模型 |
| SRDF | 语义机器人描述 | 规划组、预设姿态等 |
| IK / FK | 逆/正运动学 | 位姿与关节角之间的求解 |
| MoveIt 2 | 运动规划框架 | 生成和执行机器人轨迹 |
| OMPL | 运动规划库 | 提供 RRTConnect 等算法 |
| RViz | 可视化工具 | 显示机器人、TF 和规划路径 |
| CoppeliaSim | 机器人仿真软件 | 模拟机器人和环境 |
| ZMQ Remote API | 远程调用接口 | Python 与 CoppeliaSim 通信 |
| Gymnasium | RL 环境规范 | 定义 reset/step 等接口 |
| SAC | 软演员评论家算法 | 连续动作强化学习方法 |


---

> **最终记忆：** ROS 2 的核心是“让模块之间可靠协作”。先掌握 **Node → Topic / Service / Action → TF → URDF / SRDF → MoveIt 2 → 执行反馈**，再研究强化学习或扩散策略，知识就能串起来。
