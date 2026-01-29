#!/usr/bin/env bash
set -euo pipefail

# NCCL 性能测试脚本 (单节点多卡)
# 使用 NVIDIA nccl-tests 的 all_reduce_perf

: "${OUTPUT_DIR:=/results}"
: "${GPU_COUNT:=$(nvidia-smi -L | wc -l || echo 8)}"
: "${START_SIZE:=-b 8M}"
: "${END_SIZE:=-e 1G}"
: "${STEP_FACTOR:=-f 2}"

NODE_NAME="${NODE_NAME:-$(hostname)}"
OUTPUT_FILE="$OUTPUT_DIR/nccl_perf_${NODE_NAME}.json"

mkdir -p "$OUTPUT_DIR"

echo "=== NCCL 性能测试 (nccl-tests) ==="
echo "节点: $NODE_NAME"
echo "GPU 数量: $GPU_COUNT"
echo "输出目录: $OUTPUT_DIR"
echo ""

# 检查 nccl-tests 是否已安装
if [ ! -f /nccl-tests/build/all_reduce_perf ]; then
  echo "错误: nccl-tests 未找到"
  echo "请使用包含 nccl-tests 的镜像或通过 init container 安装"
  exit 1
fi

# 运行测试，同时保存原始输出和解析 JSON
RAW_OUTPUT="$OUTPUT_DIR/nccl_perf_${NODE_NAME}.log"

/nccl-tests/build/all_reduce_perf \
  $START_SIZE \
  $END_SIZE \
  $STEP_FACTOR \
  -g $GPU_COUNT \
  2>&1 | tee "$RAW_OUTPUT"

# 解析输出为 JSON
python3 <<'PY'
import os
import re
import json

output_dir = os.environ.get("OUTPUT_DIR", "/results")
node_name = os.environ.get("NODE_NAME", "unknown")
raw_file = f"{output_dir}/nccl_perf_{node_name}.log"
output_file = os.environ.get("OUTPUT_FILE", f"{output_dir}/nccl_perf_{node_name}.json")

result = {
    "test": "nccl_perf",
    "node_name": node_name,
    "status": "success",
    "results": []
}

with open(raw_file, "r") as f:
    lines = f.readlines()

# 解析输出
# 示例行: 8388608       2097152     float     sum      -1    84.57   99.19  173.59       0
in_results = False
for line in lines:
    if "# Using devices" in line:
        # 提取 GPU 信息
        result["devices"] = []
        continue

    if "#       size" in line:
        in_results = True
        continue

    if in_results and line.strip() and not line.startswith("#"):
        parts = line.split()
        if len(parts) >= 10:
            try:
                size_bytes = int(parts[0])
                time_us = float(parts[5])
                algbw = float(parts[6])
                busbw = float(parts[7])

                result["results"].append({
                    "size_bytes": size_bytes,
                    "size_mb": round(size_bytes / 1024 / 1024, 2),
                    "time_us": round(time_us, 2),
                    "algbw_gbps": round(algbw, 2),
                    "busbw_gbps": round(busbw, 2),
                })
            except ValueError:
                pass

    # 提取平均带宽
    if "Avg bus bandwidth" in line:
        parts = line.split(":")
        if len(parts) >= 2:
            result["avg_bus_bandwidth_gbps"] = round(float(parts[1].strip()), 3)

with open(output_file, "w") as f:
    json.dump(result, f, indent=2)

print(f"\n结果已保存到: {output_file}")
if "avg_bus_bandwidth_gbps" in result:
    print(f"平均总线带宽: {result['avg_bus_bandwidth_gbps']} GB/s")
PY

echo ""
echo "=== NCCL 性能测试完成 ==="
