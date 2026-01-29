#!/usr/bin/env bash
set -euo pipefail

# cuBLAS 算力测试启动脚本

: "${OUTPUT_DIR:=/results}"
: "${MATRIX_SIZE:=8192}"
: "${GPU_ID:=0}"

NODE_NAME="${NODE_NAME:-$(hostname)}"
OUTPUT_FILE="$OUTPUT_DIR/cublas_test_${NODE_NAME}.json"

mkdir -p "$OUTPUT_DIR"

echo "=== cuBLAS 算力测试 ==="
echo "节点: $NODE_NAME"
echo "矩阵大小: ${MATRIX_SIZE}x${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "GPU ID: $GPU_ID"
echo ""

# 检查可执行文件
if [ ! -f /scripts/test_cublas ]; then
  echo "错误: test_cublas 可执行文件未找到"
  echo "请先编译或使用已编译的镜像"
  exit 1
fi

# 运行测试并保存结果
/scripts/test_cublas $MATRIX_SIZE $MATRIX_SIZE $MATRIX_SIZE $GPU_ID | tee "$OUTPUT_FILE"

echo ""
echo "=== cuBLAS 算力测试完成 ==="
echo "结果已保存到: $OUTPUT_FILE"
