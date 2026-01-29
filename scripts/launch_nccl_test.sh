#!/usr/bin/env bash
set -euo pipefail

# NCCL AllReduce 测试启动脚本 (K8S 版本)
# 此脚本会被 K8S Job 调用，启动 Python 测试程序

# 环境变量 (由 K8S 注入或配置)
# NCCL_IB_HCA, NCCL_SOCKET_IFNAME 等可从 ConfigMap 或环境变量传入

: "${WORLD_SIZE:=2}"
: "${MASTER_ADDR:=}"
: "${RANK:=0}"
: "${LOCAL_RANK:=0}"
: "${MASTER_PORT:=13579}"
: "${OUTPUT_DIR:=/results}"

# 检查必需参数
if [ -z "$MASTER_ADDR" ]; then
  echo "错误: MASTER_ADDR 必须设置"
  exit 1
fi

echo "=== NCCL AllReduce 测试启动 ==="
echo "WORLD_SIZE: $WORLD_SIZE"
echo "MASTER_ADDR: $MASTER_ADDR"
echo "MASTER_PORT: $MASTER_PORT"
echo "RANK: $RANK"
echo "LOCAL_RANK: $LOCAL_RANK"
echo "NCCL_IB_HCA: ${NCCL_IB_HCA:-default}"
echo "NCCL_SOCKET_IFNAME: ${NCCL_SOCKET_IFNAME:-default}"
echo ""

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 启动测试
export MASTER_ADDR
export MASTER_PORT
export WORLD_SIZE
export RANK
export LOCAL_RANK
export NODE_NAME="${NODE_NAME:-$(hostname)}"
export OUTPUT_DIR

python3 /scripts/test_allreduce.py
