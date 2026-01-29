#!/usr/bin/env bash
set -euo pipefail

# 环境检查脚本 - 容器化版本
# 输出 JSON 格式的环境报告

hr() { echo "------------------------------------------------------------"; }
sec() { hr; echo "$1"; hr; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

PY="${PYTHON:-python3}"
cmd_exists "$PY" || PY="python"
if ! cmd_exists "$PY"; then
  echo '{"error": "python/python3 not found"}'
  exit 1
fi

# 获取节点名称
NODE_NAME="${NODE_NAME:-$(hostname)}"
OUTPUT_DIR="${OUTPUT_DIR:-/results}"
mkdir -p "$OUTPUT_DIR"

OUTPUT_FILE="$OUTPUT_DIR/env_check_${NODE_NAME}.json"

# 开始构建 JSON
echo "{" > "$OUTPUT_FILE"
echo "  \"node_name\": \"$NODE_NAME\"," >> "$OUTPUT_FILE"
echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$OUTPUT_FILE"

# [A] CUDA 驱动版本
sec "[A] CUDA 驱动版本"
if cmd_exists nvidia-smi; then
  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  cud="$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
  gpu_count="$(nvidia-smi -L 2>/dev/null | wc -l || true)"

  echo "  \"nvidia_driver_version\": \"${drv:-unknown}\"," >> "$OUTPUT_FILE"
  echo "  \"cuda_version\": \"${cud:-unknown}\"," >> "$OUTPUT_FILE"
  echo "  \"gpu_name\": \"${gpu_name:-unknown}\"," >> "$OUTPUT_FILE"
  echo "  \"gpu_count\": ${gpu_count:-0}," >> "$OUTPUT_FILE"
  echo "  \"nvidia_smi_available\": true," >> "$OUTPUT_FILE"
else
  echo "  \"nvidia_smi_available\": false," >> "$OUTPUT_FILE"
  echo "  \"nvidia_driver_version\": \"not found\"," >> "$OUTPUT_FILE"
  echo "  \"gpu_count\": 0," >> "$OUTPUT_FILE"
fi

# [B] Python 运行环境
sec "[B] Python 运行环境"
PY_VERSION="$("$PY" -V 2>&1)"
PY_EXEC="$(command -v "$PY")"
echo "  \"python_version\": \"$PY_VERSION\"," >> "$OUTPUT_FILE"
echo "  \"python_exec\": \"$PY_EXEC\"," >> "$OUTPUT_FILE"
echo "  \"conda_prefix\": \"${CONDA_PREFIX:-}\"," >> "$OUTPUT_FILE"
echo "  \"virtual_env\": \"${VIRTUAL_ENV:-}\"," >> "$OUTPUT_FILE"

if cmd_exists pip; then
  PIP_VERSION="$(pip -V 2>&1 || true)"
  echo "  \"pip_version\": \"$PIP_VERSION\"," >> "$OUTPUT_FILE"
else
  echo "  \"pip_version\": \"$("$PY" -m pip -V 2>&1 || echo 'not found')\"," >> "$OUTPUT_FILE"
fi

# [C] Torch / sglang 及关键依赖版本
sec "[C] Torch / sglang 及关键依赖版本"

"$PY" - <<'PY' > /tmp/packages.json
from importlib import metadata
import json

def ver(name: str):
    try:
        return metadata.version(name)
    except Exception:
        return None

pkgs = [
    "sglang",
    "torch", "torchvision", "torchaudio",
    "transformers", "tokenizers", "safetensors", "huggingface_hub", "accelerate",
    "triton",
    "flash-attn", "flash_attn",
    "xformers",
    "bitsandbytes",
    "fastapi", "uvicorn", "pydantic", "starlette",
]

result = {}
for n in pkgs:
    v = ver(n)
    if v:
        result[n] = v

print(json.dumps(result))
PY

# 格式化包版本 JSON
if [ -f /tmp/packages.json ]; then
  echo "  \"packages\": $(cat /tmp/packages.json)," >> "$OUTPUT_FILE"
fi

# Torch 详细信息
"$PY" - <<'PY' > /tmp/torch_details.json
import json
import sys

try:
    import torch
    result = {
        "torch_version": getattr(torch, "__version__", None),
        "cuda_version": getattr(torch.version, "cuda", None),
        "cuda_available": torch.cuda.is_available(),
        "gpu_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    }
    try:
        result["cudnn_version"] = torch.backends.cudnn.version()
    except Exception:
        result["cudnn_version"] = None

    # 获取每张 GPU 的信息
    if torch.cuda.is_available():
        gpus = []
        for i in range(torch.cuda.device_count()):
            props = torch.cuda.get_device_properties(i)
            gpus.append({
                "id": i,
                "name": props.name,
                "total_memory_gb": props.total_memory / 1024**3,
            })
        result["gpus"] = gpus
except Exception as e:
    result = {"error": str(e)}

print(json.dumps(result))
PY

if [ -f /tmp/torch_details.json ]; then
  echo "  \"torch_details\": $(cat /tmp/torch_details.json)," >> "$OUTPUT_FILE"
fi

# [D] 关键环境变量
sec "[D] 关键环境变量"
echo "  \"env_vars\": {" >> "$OUTPUT_FILE"
VARS=(
  CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES
  NCCL_DEBUG NCCL_IB_DISABLE NCCL_SOCKET_IFNAME
  GLOO_SOCKET_IFNAME NCCL_IB_HCA NVSHMEM_ENABLE_NIC_PE_MAPPING
  NVSHMEM_HCA_PE_MAPPING
)
FIRST=true
for v in "${VARS[@]}"; do
  val="${!v-}"
  if [[ -n "$val" ]]; then
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >> "$OUTPUT_FILE"
    fi
    printf "    \"%s\": \"%s\"" "$v" "$val" >> "$OUTPUT_FILE"
  fi
done
echo "" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"

# [E] pip freeze (关键包)
sec "[E] pip freeze (关键包)"
"$PY" -m pip freeze 2>/dev/null | \
  egrep -i '^(sglang|torch|torchvision|torchaudio|transformers|tokenizers|safetensors|huggingface-hub|accelerate|triton|flash-attn|flash_attn|xformers|bitsandbytes|fastapi|uvicorn|pydantic|starlette)=' \
  > /tmp/pip_freeze.txt || true

if [ -s /tmp/pip_freeze.txt ]; then
  echo "  \"pip_freeze\": [" >> "$OUTPUT_FILE"
  while IFS= read -r line; do
    pkg=$(echo "$line" | cut -d'=' -f1)
    ver=$(echo "$line" | cut -d'=' -f3 | cut -d'.' -f1-3)
    echo "    {\"package\": \"$pkg\", \"version\": \"$ver\"}," >> "$OUTPUT_FILE"
  done < /tmp/pip_freeze.txt
  sed -i '$ s/,$//' "$OUTPUT_FILE"  # 移除最后的逗号
  echo "  ]," >> "$OUTPUT_FILE"
else
  echo "  \"pip_freeze\": []," >> "$OUTPUT_FILE"
fi

# 检查状态总结
echo "  \"checks\": {" >> "$OUTPUT_FILE"

# 检查 nvidia-smi
if cmd_exists nvidia-smi; then
  echo "    \"nvidia_smi\": \"pass\"," >> "$OUTPUT_FILE"
else
  echo "    \"nvidia_smi\": \"fail\"," >> "$OUTPUT_FILE"
fi

# 检查 CUDA 可用性
"$PY" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "    \"cuda_available\": \"pass\"," >> "$OUTPUT_FILE"
else
  echo "    \"cuda_available\": \"fail\"," >> "$OUTPUT_FILE"
fi

# 检查 sglang
"$PY" -c "import sglang; exit(0)" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "    \"sglang_import\": \"pass\"" >> "$OUTPUT_FILE"
else
  echo "    \"sglang_import\": \"fail\"" >> "$OUTPUT_FILE"
fi

echo "  }" >> "$OUTPUT_FILE"
echo "}" >> "$OUTPUT_FILE"

# 输出结果
echo ""
echo "=== 环境检查完成 ==="
echo "结果已保存到: $OUTPUT_FILE"
echo ""

# 也打印友好的文本输出
cat "$OUTPUT_FILE" | grep -E '(node_name|nvidia_driver_version|cuda_version|gpu_count|python_version|torch_version|cuda_available|sglang)' || true
