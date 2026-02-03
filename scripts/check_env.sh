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

# 如果旧的 JSON 文件格式有问题，删除它重新生成
if [ -f "$OUTPUT_FILE" ]; then
  # 简单检查：如果文件包含错误信息字符串，删除它
  if grep -q "not a valid field" "$OUTPUT_FILE" 2>/dev/null; then
    echo "检测到旧的损坏的 JSON 文件，重新生成..."
    rm -f "$OUTPUT_FILE"
  fi
fi

# 检查是否需要强制重新生成（由环境变量控制）
FORCE_REGENERATE="${FORCE_REGENERATE:-false}"
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ] && [ "$FORCE_REGENERATE" != "true" ]; then
  echo "环境检查已完成，结果文件已存在: $OUTPUT_FILE"
  echo "保持容器运行中..."
  # 保持容器运行，避免 DaemonSet 重启
  sleep infinity
fi

# 如果强制重新生成，删除旧文件
if [ "$FORCE_REGENERATE" = "true" ] && [ -f "$OUTPUT_FILE" ]; then
  rm -f "$OUTPUT_FILE"
fi

# 使用 Python 生成完整的 JSON 报告
sec "正在收集环境信息..."
"$PY" - <<'PYEND'
import subprocess
import sys
import os
import json
from importlib import metadata
from datetime import datetime

# 获取节点名称
node_name = os.environ.get("NODE_NAME", os.uname().nodename)
output_dir = os.environ.get("OUTPUT_DIR", "/results")
output_file = os.path.join(output_dir, f"env_check_{node_name}.json")

# ============ 收集环境信息 ============

result = {
    "node_name": node_name,
    "timestamp": datetime.now().isoformat(),
}

# [A] NVIDIA 驱动和 GPU 信息
drv = "unknown"
cud = "unknown"
gpu_name = "unknown"
gpu_count = 0
nvidia_smi_available = False

try:
    # Check if nvidia-smi exists
    proc = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True, timeout=5)
    if proc.returncode == 0:
        nvidia_smi_available = True
        gpu_count = len(proc.stdout.strip().split('\n'))

        # Get driver version
        proc = subprocess.run(['nvidia-smi', '--query-gpu=driver_version', '--format=csv,noheader'],
                              capture_output=True, text=True, timeout=5)
        if proc.returncode == 0:
            drv = proc.stdout.strip().split('\n')[0]

        # Get CUDA version (may fail on some systems)
        proc = subprocess.run(['nvidia-smi', '--query-gpu=cuda_version', '--format=csv,noheader'],
                              capture_output=True, text=True, timeout=5)
        if proc.returncode == 0:
            cud = proc.stdout.strip().split('\n')[0]
            # Filter out error messages
            if "not a valid field" in cud or len(cud) > 20:
                cud = "unknown"

        # Get GPU name
        proc = subprocess.run(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'],
                              capture_output=True, text=True, timeout=5)
        if proc.returncode == 0:
            gpu_name = proc.stdout.strip().split('\n')[0]
except Exception as e:
    pass

result["nvidia_driver_version"] = drv
result["cuda_version"] = cud
result["gpu_name"] = gpu_name
result["gpu_count"] = gpu_count
result["nvidia_smi_available"] = nvidia_smi_available

# [B] Python 运行环境
py_version = subprocess.run(['python3', '-V'], capture_output=True, text=True).stdout.strip() or "unknown"
try:
    py_exec = subprocess.run(['command', '-v', 'python3'], shell=True, capture_output=True, text=True).stdout.strip() or "unknown"
except:
    py_exec = "unknown"
conda_prefix = os.environ.get('CONDA_PREFIX', '')
virtual_env = os.environ.get('VIRTUAL_ENV', '')

# Get pip version
try:
    pip_version = subprocess.run(['pip', '-V'], capture_output=True, text=True, timeout=5).stdout.strip() or ""
    if not pip_version:
        pip_version = subprocess.run(['python3', '-m', 'pip', '-V'], capture_output=True, text=True, timeout=5).stdout.strip() or "not found"
except:
    pip_version = "not found"

result["python_version"] = py_version
result["python_exec"] = py_exec
result["conda_prefix"] = conda_prefix
result["virtual_env"] = virtual_env
result["pip_version"] = pip_version

# [C] Torch / sglang 及关键依赖版本
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

packages = {}
for n in pkgs:
    v = ver(n)
    if v:
        packages[n] = v

result["packages"] = packages

# [D] Torch 详细信息
try:
    import torch
    torch_details = {
        "torch_version": getattr(torch, "__version__", None),
        "cuda_version": getattr(torch.version, "cuda", None),
        "cuda_available": torch.cuda.is_available(),
        "gpu_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    }
    try:
        torch_details["cudnn_version"] = torch.backends.cudnn.version()
    except Exception:
        torch_details["cudnn_version"] = None

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
        torch_details["gpus"] = gpus
except Exception as e:
    torch_details = {"error": str(e)}

result["torch_details"] = torch_details

# [E] 关键环境变量
vars_to_check = [
    "CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES",
    "NCCL_DEBUG", "NCCL_IB_DISABLE", "NCCL_SOCKET_IFNAME",
    "GLOO_SOCKET_IFNAME", "NCCL_IB_HCA", "NVSHMEM_ENABLE_NIC_PE_MAPPING",
    "NVSHMEM_HCA_PE_MAPPING"
]

env_vars = {}
for v in vars_to_check:
    val = os.environ.get(v, "")
    if val:
        env_vars[v] = val

result["env_vars"] = env_vars

# [F] pip freeze (关键包)
pkgs = [
    "sglang", "torch", "torchvision", "torchaudio",
    "transformers", "tokenizers", "safetensors", "huggingface-hub",
    "accelerate", "triton", "flash-attn", "flash_attn",
    "xformers", "bitsandbytes", "fastapi", "uvicorn",
    "pydantic", "starlette"
]

pip_freeze_dict = {}
try:
    output = subprocess.run(['pip', 'freeze'], capture_output=True, text=True, timeout=30).stdout
    import re
    for line in output.strip().split('\n'):
        match = re.match(r'^([a-zA-Z0-9_-]+)==([0-9.]+)', line)
        if match:
            pkg_name = match.group(1).lower()
            if pkg_name in pkgs:
                pip_freeze_dict[pkg_name] = match.group(2)
except Exception:
    pass

# Convert to array format
pip_freeze = [{"package": k, "version": v} for k, v in pip_freeze_dict.items()]
result["pip_freeze"] = pip_freeze

# [G] 检查状态总结
checks = {}

# 检查 nvidia-smi
try:
    proc = subprocess.run(['which', 'nvidia-smi'], capture_output=True, text=True)
    checks["nvidia_smi"] = "pass" if proc.returncode == 0 else "fail"
except:
    checks["nvidia_smi"] = "fail"

# 检查 CUDA 可用性
try:
    import torch
    checks["cuda_available"] = "pass" if torch.cuda.is_available() else "fail"
except:
    checks["cuda_available"] = "fail"

# 检查 sglang
try:
    import sglang
    checks["sglang_import"] = "pass"
except:
    checks["sglang_import"] = "fail"

result["checks"] = checks

# ============ 保存结果 ============
with open(output_file, "w") as f:
    json.dump(result, f, indent=2)

print(f"环境检查完成，结果已保存到: {output_file}")
PYEND

# 输出结果摘要
echo ""
echo "=== 环境检查完成 ==="
echo "结果已保存到: $OUTPUT_FILE"
echo ""

# 也打印友好的文本输出
"$PY" -c "
import json
import os
with open(os.environ.get('OUTPUT_FILE', '$OUTPUT_FILE')) as f:
    d = json.load(f)
    print(f\"节点: {d.get('node_name', 'unknown')}\")
    print(f\"GPU: {d.get('gpu_name', 'unknown')} x{d.get('gpu_count', 0)}\")
    print(f\"驱动版本: {d.get('nvidia_driver_version', 'unknown')}\")
    print(f\"Python: {d.get('python_version', 'unknown')}\")
    print(f\"Torch: {d.get('torch_details', {}).get('torch_version', 'unknown')}\")
    print(f\"CUDA 可用: {d.get('torch_details', {}).get('cuda_available', False)}\")
    print(f\"sglang: {'✓' if d.get('checks', {}).get('sglang_import') == 'pass' else '✗'}\")
" 2>/dev/null || true

# 保持容器运行，避免 DaemonSet 不断重启
echo ""
echo "环境检查完成，保持容器运行..."
sleep infinity
