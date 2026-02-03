#!/usr/bin/env bash
# K8S 环境测试配置文件
# 修改此文件后运行 ./generate_yaml.sh 即可更新所有 YAML 文件

# === 基础配置 ===
NAMESPACE="default"                 # Kubernetes 命名空间

# === 路径配置 ===
SCRIPTS_HOST_PATH="/data/zyn/k8s-env-test/scripts"  # 脚本在宿主机上的路径
RESULTS_HOST_PATH="/tmp/env-test-results"          # 结果输出路径

# === 节点选择 ===
# 指定要使用的节点主机名（多个节点用空格分隔）
NODE_NAMES="gpu203 gpu217"          # 指定测试节点
# 如果使用 nodeSelector 方式（匹配单个标签值）
NODE_SELECTOR_KEY="gpu"             # 节点标签的 key
NODE_SELECTOR_VALUE="true"          # 节点标签的 value
# 示例：如果有多个标签条件，可以写成
# NODE_SELECTOR="- gpu: 'true'\n  - node-type: 'worker'"

# === GPU 配置 ===
GPU_COUNT_PER_NODE="8"              # 每节点 GPU 数量 (用于性能测试)

# === NCCL 网络配置 ===
NCCL_SOCKET_IFNAME="enp25s0np0"     # 以太网网卡名
NCCL_IB_HCA="mlx5_0"                         # InfiniBand 设备名
NCCL_IB_DISABLE="0"                          # 是否禁用 IB (0=启用, 1=禁用)
GLOO_SOCKET_IFNAME="enp25s0np0"     # GLOO 网卡名

# === 测试节点配置 ===
NCCL_TEST_REPLICAS="2"               # NCCL 互通测试的节点数
NCCL_PERF_REPLICAS="2"               # NCCL 性能测试的节点数
CUBLAS_REPLICAS="1"                  # cuBLAS 测试的节点数

# === 镜像配置 ===
IMAGE_NAME="docker.1ms.run/lmsysorg/sglang"                  # 镜像名称
IMAGE_TAG="v0.5.6.post2"                   # 镜像标签
IMAGE_PULL_POLICY="IfNotPresent"     # 镜像拉取策略

# === 资源限制配置 ===
# 环境检查
ENV_CHECK_MEMORY_REQUEST="1Gi"
ENV_CHECK_CPU_REQUEST="500m"
ENV_CHECK_MEMORY_LIMIT="2Gi"
ENV_CHECK_CPU_LIMIT="1000m"

# NCCL 测试
NCCL_TEST_MEMORY_REQUEST="2Gi"
NCCL_TEST_CPU_REQUEST="1000m"
NCCL_TEST_MEMORY_LIMIT="4Gi"
NCCL_TEST_CPU_LIMIT="2000m"

# NCCL 性能测试
NCCL_PERF_MEMORY_REQUEST="4Gi"
NCCL_PERF_CPU_REQUEST="2000m"
NCCL_PERF_MEMORY_LIMIT="8Gi"
NCCL_PERF_CPU_LIMIT="4000m"

# cuBLAS 测试
CUBLAS_TEST_MEMORY_REQUEST="8Gi"
CUBLAS_TEST_CPU_REQUEST="2000m"
CUBLAS_TEST_MEMORY_LIMIT="16Gi"
CUBLAS_TEST_CPU_LIMIT="4000m"
