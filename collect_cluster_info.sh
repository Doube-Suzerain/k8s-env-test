#!/usr/bin/env bash
# K8S 集群信息收集脚本
# 用于自动收集配置 config.sh 所需的集群信息

echo "=========================================="
echo "     K8S 集群环境信息收集工具"
echo "=========================================="
echo ""

# 检查 kubectl
if ! command -v kubectl &> /dev/null; then
    echo "[错误] kubectl 未找到，请先安装 kubectl"
    exit 1
fi

# 检查集群连接
if ! kubectl cluster-info &> /dev/null; then
    echo "[错误] 无法连接到 Kubernetes 集群"
    echo "请检查 kubeconfig 配置: export KUBECONFIG=/path/to/kubeconfig"
    exit 1
fi

echo "=========================================="
echo "1. 集群基本信息"
echo "=========================================="
echo "当前上下文: $(kubectl config current-context)"
echo "集群服务器: $(kubectl config view -o jsonpath='{.clusters[?(@.name == "$(kubectl config current-context)")].cluster.server}' 2>/dev/null || echo "无法获取")"
echo ""

echo "=========================================="
echo "2. 节点列表及标签"
echo "=========================================="
kubectl get nodes --show-labels
echo ""

echo "=========================================="
echo "3. 节点资源概览"
echo "=========================================="
printf "%-25s %-8s %-10s %-12s\n" "NAME" "GPU" "CPU" "MEMORY"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\t"}{.status.allocatable.cpu}{"\t"}{.status.allocatable.memory}{"\n"}{end}' | \
    awk 'BEGIN {OFS="\t"} {printf "%-25s %-8s %-10s %-12s\n", $1, $2, $3, $4}'
echo ""

echo "=========================================="
echo "4. 命名空间列表"
echo "=========================================="
kubectl get namespaces
echo ""

echo "=========================================="
echo "5. GPU 相关检查"
echo "=========================================="
echo -n "NVIDIA Device Plugin: "
if kubectl get pod -n kube-system 2>/dev/null | grep -qi nvidia; then
    kubectl get pod -n kube-system | grep nvidia
else
    echo "未找到 nvidia-device-plugin"
fi
echo ""

echo "带 GPU 的 Pod:"
GPU_PODS=$(kubectl get pods -A -o jsonpath='{range .items[?(@.spec.containers[*].resources.limits.nvidia\.com/gpu)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | head -5)
if [ -n "$GPU_PODS" ]; then
    echo "$GPU_PODS"
else
    echo "  (当前没有使用 GPU 的 Pod)"
fi
echo ""

echo "=========================================="
echo "6. 存储相关 (PV/PVC)"
echo "=========================================="
echo "PersistentVolumes:"
kubectl get pv 2>/dev/null | head -5 || echo "  无 PV 资源"
echo ""
echo "PersistentVolumeClaims:"
kubectl get pvc -A 2>/dev/null | head -5 || echo "  无 PVC 资源"
echo ""

echo "=========================================="
echo "7. 常用镜像 (sglang/nvidia/cuda 相关)"
echo "=========================================="
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | \
    grep -iE "sglang|nvidia|cuda" | sort -u | head -10 || echo "  未找到相关镜像"
echo ""

echo "=========================================="
echo "8. 网络 Service (用于参考)"
echo "=========================================="
kubectl get svc -A | head -10
echo ""

echo "=========================================="
echo "========== 建议的 config.sh 配置 =========="
echo "=========================================="
echo ""

# 获取第一个 GPU 节点的信息
FIRST_GPU_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
FIRST_NODE_LABELS=$(kubectl get node "$FIRST_GPU_NODE" -o jsonpath='{.metadata.labels}' 2>/dev/null)

echo "# === 节点选择 ==="
# 尝试找常见的 GPU 标签
GPU_LABEL_KEY=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.gpu}' 2>/dev/null | head -1)
if [ -n "$GPU_LABEL_KEY" ]; then
    echo "NODE_SELECTOR_KEY=\"gpu\""
    echo "NODE_SELECTOR_VALUE=\"$GPU_LABEL_KEY\""
else
    echo "# 请根据上面的节点标签手动选择"
    echo "NODE_SELECTOR_KEY=\"node-label-key\""
    echo "NODE_SELECTOR_VALUE=\"node-label-value\""
fi
echo ""

echo "# === GPU 配置 ==="
GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
if [ -n "$GPU_COUNT" ]; then
    echo "GPU_COUNT_PER_NODE=\"$GPU_COUNT\""
else
    echo "GPU_COUNT_PER_NODE=\"请根据节点资源手动填写\""
fi
echo ""

echo "# === 命名空间 ==="
CURRENT_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
echo "NAMESPACE=\"${CURRENT_NS:-default}\""
echo ""

echo "# === 路径配置 (需要手动确认) ==="
echo "SCRIPTS_HOST_PATH=\"/path/to/k8s-env-test/scripts\"  # 请修改为实际路径！"
echo "RESULTS_HOST_PATH=\"/tmp/env-test-results\""
echo ""

echo "# === 镜像配置 (根据实际镜像仓库修改) ==="
echo "IMAGE_NAME=\"sglang\""
echo "IMAGE_TAG=\"v0.5.7\""
echo ""

echo "=========================================="
echo "信息收集完成！"
echo "=========================================="
echo ""
echo "后续步骤:"
echo "1. 根据上述信息编辑 config.sh 文件"
echo "2. 运行 ./generate_yaml.sh 生成 YAML 文件"
echo "3. 运行 ./run_all.sh 执行测试"
echo ""
echo "如需更详细的配置说明，请参阅: K8S_CONFIG_GUIDE.md"
