#!/usr/bin/env bash
set -euo pipefail

# 集群环境测试一键执行脚本
# 用法: ./run_all.sh [options]
# 选项:
#   --skip-env       跳过环境检查
#   --skip-nccl      跳过 NCCL 测试
#   --skip-perf      跳过性能测试
#   --skip-cublas    跳过 cuBLAS 测试
#   --nodes N        设置节点数 (默认: 2)
#   --namespace NS   设置命名空间 (默认: default)
#   --scripts-path   脚本路径 (默认: 当前目录/scripts)
#   --results-path   结果路径 (默认: /tmp/env-test-results)
#   --cleanup        测试完成后清理资源
#   -h, --help       显示帮助

# 默认配置
SKIP_ENV=false
SKIP_NCCL=false
SKIP_PERF=false
SKIP_CUBLAS=false
NODES=2
NAMESPACE="default"
SCRIPTS_PATH="$(pwd)/scripts"
RESULTS_PATH="/tmp/env-test-results"
CLEANUP=false

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-env)
      SKIP_ENV=true
      shift
      ;;
    --skip-nccl)
      SKIP_NCCL=true
      shift
      ;;
    --skip-perf)
      SKIP_PERF=true
      shift
      ;;
    --skip-cublas)
      SKIP_CUBLAS=true
      shift
      ;;
    --nodes)
      NODES="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --scripts-path)
      SCRIPTS_PATH="$2"
      shift 2
      ;;
    --results-path)
      RESULTS_PATH="$2"
      shift 2
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    -h|--help)
      echo "用法: $0 [options]"
      echo "选项:"
      echo "  --skip-env       跳过环境检查"
      echo "  --skip-nccl      跳过 NCCL 测试"
      echo "  --skip-perf      跳过性能测试"
      echo "  --skip-cublas    跳过 cuBLAS 测试"
      echo "  --nodes N        设置节点数 (默认: 2)"
      echo "  --namespace NS   设置命名空间 (默认: default)"
      echo "  --scripts-path   脚本路径"
      echo "  --results-path   结果路径"
      echo "  --cleanup        测试完成后清理资源"
      echo "  -h, --help       显示帮助"
      exit 0
      ;;
    *)
      log_error "未知参数: $1"
      exit 1
      ;;
  esac
done

# 检查 kubectl
if ! command -v kubectl &> /dev/null; then
  log_error "kubectl 未找到，请先安装 kubectl"
  exit 1
fi

# 检查集群连接
if ! kubectl cluster-info &> /dev/null; then
  log_error "无法连接到 Kubernetes 集群"
  exit 1
fi

log_info "集群环境测试开始"
log_info "命名空间: $NAMESPACE"
log_info "脚本路径: $SCRIPTS_PATH"
log_info "结果路径: $RESULTS_PATH"

# 清空结果输出路径（避免旧结果干扰）
if [ -d "$RESULTS_PATH" ]; then
  log_info "清空结果输出路径: $RESULTS_PATH"
  rm -rf "${RESULTS_PATH:?}"/* 2>/dev/null || {
    log_warn "权限不足，尝试使用 sudo 清空..."
    sudo rm -rf "${RESULTS_PATH:?}"/*
  }
else
  mkdir -p "$RESULTS_PATH"
fi

# 确保脚本目录存在
if [ ! -d "$SCRIPTS_PATH" ]; then
  log_error "脚本目录不存在: $SCRIPTS_PATH"
  exit 1
fi

# 替换 YAML 文件中的路径占位符
prepare_yaml() {
  local yaml_file="$1"
  local tmp_file="${yaml_file}.tmp"

  sed "s|/path/to/k8s-env-test/scripts|$SCRIPTS_PATH|g" "$yaml_file" > "$tmp_file"
  sed -i "s|/tmp/env-test-results|$RESULTS_PATH|g" "$tmp_file"
  sed -i "s|namespace: default|namespace: $NAMESPACE|g" "$tmp_file"
  sed -i "s|replicas: 2|replicas: $NODES|g" "$tmp_file"
  sed -i "s|completions: 2|completions: $NODES|g" "$tmp_file"
  sed -i "s|parallelism: 2|parallelism: $NODES|g" "$tmp_file"

  echo "$tmp_file"
}

# 清理函数
cleanup_resources() {
  log_warn "清理测试资源..."
  kubectl delete -f k8s/01-env-check-daemonset.yaml --namespace="$NAMESPACE" --ignore-not-found=true
  kubectl delete -f k8s/02-nccl-interop-job.yaml --namespace="$NAMESPACE" --ignore-not-found=true
  kubectl delete -f k8s/03-nccl-perf-job.yaml --namespace="$NAMESPACE" --ignore-not-found=true
  kubectl delete -f k8s/04-cublas-job.yaml --namespace="$NAMESPACE" --ignore-not-found=true
  kubectl delete -f k8s/05-report-job.yaml --namespace="$NAMESPACE" --ignore-not-found=true
  log_info "清理完成"
}

# 设置清理陷阱
trap cleanup_resources EXIT

# ==================== Job 1: 环境检查 ====================
if [ "$SKIP_ENV" = false ]; then
  log_info "部署 Job 1: 环境检查 DaemonSet..."
  tmp_yaml=$(prepare_yaml "k8s/01-env-check-daemonset.yaml")
  kubectl apply -f "$tmp_yaml"
  rm -f "$tmp_yaml"

  # 等待完成
  log_info "等待环境检查完成..."
  kubectl wait --for=condition=ready pod -l app=env-check --namespace="$NAMESPACE" --timeout=300s || true
fi

# ==================== Job 2: NCCL 节点互通测试 ====================
if [ "$SKIP_NCCL" = false ]; then
  log_info "部署 Job 2: NCCL 节点互通测试..."
  tmp_yaml=$(prepare_yaml "k8s/02-nccl-interop-job.yaml")

  # 需要手动设置 MASTER_ADDR 和 RANK
  # 这里简化处理，实际需要更复杂的逻辑
  kubectl apply -f "$tmp_yaml"
  rm -f "$tmp_yaml"

  log_info "等待 NCCL 测试完成 (需要手动配置 MASTER_ADDR)..."
  sleep 30
fi

# ==================== Job 3: NCCL 性能测试 ====================
if [ "$SKIP_PERF" = false ]; then
  log_info "部署 Job 3: NCCL 性能测试..."
  tmp_yaml=$(prepare_yaml "k8s/03-nccl-perf-job.yaml")
  kubectl apply -f "$tmp_yaml"
  rm -f "$tmp_yaml"

  log_info "等待 NCCL 性能测试完成 (可能需要几分钟)..."
  kubectl wait --for=condition=complete job/nccl-perf-test --namespace="$NAMESPACE" --timeout=600s || true
fi

# ==================== Job 4: cuBLAS 算力测试 ====================
if [ "$SKIP_CUBLAS" = false ]; then
  log_info "部署 Job 4: cuBLAS 算力测试..."
  tmp_yaml=$(prepare_yaml "k8s/04-cublas-job.yaml")
  kubectl apply -f "$tmp_yaml"
  rm -f "$tmp_yaml"

  log_info "等待 cuBLAS 测试完成..."
  kubectl wait --for=condition=complete job/cublas-test --namespace="$NAMESPACE" --timeout=600s || true
fi

# ==================== Job 5: 报告汇总 ====================
log_info "部署 Job 5: 报告汇总..."
tmp_yaml=$(prepare_yaml "k8s/05-report-job.yaml")
kubectl apply -f "$tmp_yaml"
rm -f "$tmp_yaml"

log_info "等待报告生成..."
kubectl wait --for=condition=complete job/env-test-report --namespace="$NAMESPACE" --timeout=120s || true

# ==================== 收集结果 ====================
log_info "收集测试结果..."

# 直接从每个 env-check Pod 收集结果文件到本地
RESULT_DIR="$(pwd)/collected_results"
rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

PODS=$(kubectl get pods -l app=env-check --namespace="$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

for POD in $PODS; do
  NODE=$(kubectl get pod "$POD" --namespace="$NAMESPACE" -o jsonpath='{.spec.nodeName}')
  kubectl exec "$POD" --namespace="$NAMESPACE" -- cat "/results/env_check_${NODE}.json" > "$RESULT_DIR/env_check_${NODE}.json" 2>/dev/null || true
  log_info "  收集 ${NODE} 的结果"
done

# 用本地 Python 脚本生成报告
export RESULTS_DIR="$RESULT_DIR"
export OUTPUT_FILE="$(pwd)/test_report.json"
python3 "$SCRIPTS_PATH/collect_results.py"

# 注意：collect_results.py 会把 md 文件保存到和 json 文件相同的目录（即当前目录）
# 如果 md 文件不存在（生成失败），创建一个空模板
if [ ! -f "test_report.md" ]; then
  echo "# 集群环境测试报告" > test_report.md
  echo "" >> test_report.md
  echo "报告生成失败，请检查日志" >> test_report.md
fi

log_info "测试报告已保存到:"
log_info "  - $(pwd)/test_report.json"
log_info "  - $(pwd)/test_report.md"

# 显示摘要
if [ -f test_report.json ]; then
  log_info "测试摘要:"
  python3 -c "import json; d=json.load(open('test_report.json')); print(json.dumps(d.get('summary', {}), indent=2))" 2>/dev/null || true
fi

# 保留临时文件以便调试
# rm -rf "$RESULT_DIR"
log_info "原始结果文件保存在: $RESULT_DIR"

# 取消清理陷阱
trap - EXIT

# 根据参数决定是否清理
if [ "$CLEANUP" = true ]; then
  cleanup_resources
else
  log_warn "测试资源未清理，使用 --cleanup 参数可在测试完成后自动清理"
  log_warn "手动清理命令: kubectl delete -f k8s/ --namespace=$NAMESPACE"
fi

log_info "集群环境测试完成"
