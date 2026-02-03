#!/usr/bin/env bash
set -euo pipefail

# YAML 生成脚本
# 根据 config.sh 的配置生成所有 YAML 文件

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 加载配置
if [ ! -f "config.sh" ]; then
  echo "错误: 找不到 config.sh 配置文件"
  exit 1
fi

# 加载配置变量
source config.sh

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 生成完整的镜像名
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# 输出目录
OUTPUT_DIR="k8s"
mkdir -p "$OUTPUT_DIR"

log_info "开始生成 YAML 文件..."
log_info "命名空间: $NAMESPACE"
log_info "镜像: $FULL_IMAGE"
log_info "脚本路径: $SCRIPTS_HOST_PATH"

# ==================== 通用模板片段 ====================

# 生成 volumes 部分
cat_volumes() {
  cat <<EOF
      volumes:
      - name: scripts
        hostPath:
          path: ${SCRIPTS_HOST_PATH}
      - name: results
        hostPath:
          path: ${RESULTS_HOST_PATH}
EOF
}

# 生成 nodeSelector 或 nodeAffinity 部分
cat_node_selector() {
  # 如果配置了 NODE_NAMES，使用 nodeAffinity 匹配多个节点
  if [ -n "${NODE_NAMES:-}" ]; then
    # 构建节点列表
    local values_list=""
    local first=true
    for node in $NODE_NAMES; do
      if [ "$first" = true ]; then
        first=false
        values_list="                - ${node}"
      else
        values_list="${values_list}
                - ${node}"
      fi
    done

    cat <<EOF
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
${values_list}
EOF
  else
    # 否则使用简单的 nodeSelector
    cat <<EOF
      nodeSelector:
        ${NODE_SELECTOR_KEY}: "${NODE_SELECTOR_VALUE}"
EOF
  fi
}

# 生成 NCCL 环境变量
cat_nccl_env() {
  cat <<EOF
        - name: NCCL_SOCKET_IFNAME
          value: "${NCCL_SOCKET_IFNAME}"
        - name: NCCL_IB_HCA
          value: "${NCCL_IB_HCA}"
        - name: NCCL_IB_DISABLE
          value: "${NCCL_IB_DISABLE}"
        - name: GLOO_SOCKET_IFNAME
          value: "${GLOO_SOCKET_IFNAME}"
EOF
}

# ==================== 01-env-check-daemonset.yaml ====================

log_info "生成 01-env-check-daemonset.yaml..."

cat > "${OUTPUT_DIR}/01-env-check-daemonset.yaml" <<EOF
---
# Job 1: 环境检查 DaemonSet
# 在每个节点上运行环境检查脚本
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: env-check
  namespace: ${NAMESPACE}
  labels:
    app: env-check
spec:
  selector:
    matchLabels:
      app: env-check
  template:
    metadata:
      labels:
        app: env-check
    spec:
$(cat_node_selector)
$(cat_volumes)
      containers:
      - name: checker
        image: ${FULL_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["/bin/bash", "/scripts/check_env.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: OUTPUT_DIR
          value: /results
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: results
          mountPath: /results
        resources:
          requests:
            memory: ${ENV_CHECK_MEMORY_REQUEST}
            cpu: ${ENV_CHECK_CPU_REQUEST}
          limits:
            memory: ${ENV_CHECK_MEMORY_LIMIT}
            cpu: ${ENV_CHECK_CPU_LIMIT}
      restartPolicy: Always
EOF

# ==================== 02-nccl-interop-job.yaml ====================

log_info "生成 02-nccl-interop-job.yaml..."

cat > "${OUTPUT_DIR}/02-nccl-interop-job.yaml" <<EOF
---
# Job 2: NCCL 节点互通测试
# 使用 StatefulSet 实现，支持多节点 NCCL 通信
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nccl-test
  namespace: ${NAMESPACE}
spec:
  replicas: ${NCCL_TEST_REPLICAS}
  serviceName: nccl-test-headless
  selector:
    matchLabels:
      app: nccl-test
  template:
    metadata:
      labels:
        app: nccl-test
    spec:
$(cat_node_selector)
      hostNetwork: true
$(cat_volumes)
      containers:
      - name: tester
        image: ${FULL_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["/bin/bash", "/scripts/launch_nccl_test.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: OUTPUT_DIR
          value: /results
        - name: WORLD_SIZE
          value: "${NCCL_TEST_REPLICAS}"
        - name: MASTER_PORT
          value: "13579"
$(cat_nccl_env)
        - name: RANK
          valueFrom:
            fieldRef:
              fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: results
          mountPath: /results
        resources:
          requests:
            memory: ${NCCL_TEST_MEMORY_REQUEST}
            cpu: ${NCCL_TEST_CPU_REQUEST}
            nvidia.com/gpu: 1
          limits:
            memory: ${NCCL_TEST_MEMORY_LIMIT}
            cpu: ${NCCL_TEST_CPU_LIMIT}
            nvidia.com/gpu: 1
  podManagementPolicy: Parallel
---
# Headless Service 用于 StatefulSet Pod 间通信
apiVersion: v1
kind: Service
metadata:
  name: nccl-test-headless
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector:
    app: nccl-test
  ports:
  - port: 13579
    name: nccl
EOF

# ==================== 03-nccl-perf-job.yaml ====================

log_info "生成 03-nccl-perf-job.yaml..."

cat > "${OUTPUT_DIR}/03-nccl-perf-job.yaml" <<EOF
---
# Job 3: NCCL 性能测试 (单节点多卡)
# 使用 Job 在每台机器上运行 nccl-tests
apiVersion: batch/v1
kind: Job
metadata:
  name: nccl-perf-test
  namespace: ${NAMESPACE}
spec:
  completions: ${NCCL_PERF_REPLICAS}
  parallelism: ${NCCL_PERF_REPLICAS}
  completionMode: Indexed
  template:
    metadata:
      labels:
        app: nccl-perf-test
    spec:
$(cat_node_selector)
      volumes:
      - name: scripts
        hostPath:
          path: ${SCRIPTS_HOST_PATH}
      - name: results
        hostPath:
          path: ${RESULTS_HOST_PATH}
      - name: nccl-tests
        emptyDir: {}
      initContainers:
      - name: prepare-nccl-tests
        image: nvidia/cuda:12.9.0-devel-ubuntu22.04
        command:
        - /bin/bash
        - -c
        - |
          apt-get update && apt-get install -y git wget
          git clone https://github.com/NVIDIA/nccl-tests.git /tmp/nccl-tests
          cd /tmp/nccl-tests
          git checkout \$(git describe --tags \`git rev-list --tags --max-count=1\`)
          make MPI=0 CUDA_HOME=/usr/local/cuda -j\$(nproc)
          cp -r build /nccl-tests/
        volumeMounts:
        - name: nccl-tests
          mountPath: /nccl-tests
      containers:
      - name: tester
        image: ${FULL_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["/bin/bash", "/scripts/run_nccl_perf.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: JOB_COMPLETION_INDEX
          valueFrom:
            fieldRef:
              fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
        - name: OUTPUT_DIR
          value: /results
        - name: GPU_COUNT
          value: "${GPU_COUNT_PER_NODE}"
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: results
          mountPath: /results
        - name: nccl-tests
          mountPath: /nccl-tests
          readOnly: true
        resources:
          requests:
            memory: ${NCCL_PERF_MEMORY_REQUEST}
            cpu: ${NCCL_PERF_CPU_REQUEST}
            nvidia.com/gpu: ${GPU_COUNT_PER_NODE}
          limits:
            memory: ${NCCL_PERF_MEMORY_LIMIT}
            cpu: ${NCCL_PERF_CPU_LIMIT}
            nvidia.com/gpu: ${GPU_COUNT_PER_NODE}
      restartPolicy: OnFailure
EOF

# ==================== 04-cublas-job.yaml ====================

log_info "生成 04-cublas-job.yaml..."

cat > "${OUTPUT_DIR}/04-cublas-job.yaml" <<EOF
---
# Job 4: cuBLAS 算力测试
apiVersion: batch/v1
kind: Job
metadata:
  name: cublas-test
  namespace: ${NAMESPACE}
spec:
  completions: ${CUBLAS_REPLICAS}
  parallelism: ${CUBLAS_REPLICAS}
  template:
    metadata:
      labels:
        app: cublas-test
    spec:
$(cat_node_selector)
      volumes:
      - name: scripts
        hostPath:
          path: ${SCRIPTS_HOST_PATH}
      - name: results
        hostPath:
          path: ${RESULTS_HOST_PATH}
      initContainers:
      - name: compile-cublas-test
        image: nvidia/cuda:12.9.0-devel-ubuntu22.04
        command:
        - /bin/bash
        - -c
        - |
          cd /scripts
          nvcc test_cublas.cpp -o test_cublas -lcublasLt -lcublas -lcudart -std=c++17
          ls -la test_cublas
        volumeMounts:
        - name: scripts
          mountPath: /scripts
      containers:
      - name: tester
        image: ${FULL_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["/bin/bash", "/scripts/run_cublas_test.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: OUTPUT_DIR
          value: /results
        - name: MATRIX_SIZE
          value: "8192"
        - name: GPU_ID
          value: "0"
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: results
          mountPath: /results
        resources:
          requests:
            memory: ${CUBLAS_TEST_MEMORY_REQUEST}
            cpu: ${CUBLAS_TEST_CPU_REQUEST}
            nvidia.com/gpu: 1
          limits:
            memory: ${CUBLAS_TEST_MEMORY_LIMIT}
            cpu: ${CUBLAS_TEST_CPU_LIMIT}
            nvidia.com/gpu: 1
      restartPolicy: OnFailure
EOF

# ==================== 05-report-job.yaml ====================

log_info "生成 05-report-job.yaml..."

cat > "${OUTPUT_DIR}/05-report-job.yaml" <<EOF
---
# Job 5: 报告汇总
apiVersion: batch/v1
kind: Job
metadata:
  name: env-test-report
  namespace: ${NAMESPACE}
spec:
  template:
    metadata:
      labels:
        app: env-test-report
    spec:
      volumes:
      - name: scripts
        hostPath:
          path: ${SCRIPTS_HOST_PATH}
      - name: results
        hostPath:
          path: ${RESULTS_HOST_PATH}
      containers:
      - name: reporter
        image: ${FULL_IMAGE}
        imagePullPolicy: ${IMAGE_PULL_POLICY}
        command: ["/usr/bin/python3", "/scripts/collect_results.py"]
        env:
        - name: RESULTS_DIR
          value: /results
        - name: OUTPUT_FILE
          value: /results/test_report.json
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: results
          mountPath: /results
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      restartPolicy: OnFailure
EOF

# ==================== 完成 ====================

log_info "所有 YAML 文件已生成到 ${OUTPUT_DIR}/ 目录"
echo ""
echo "生成的文件："
ls -la "${OUTPUT_DIR}"/*.yaml
echo ""
log_warn "请检查生成的 YAML 文件，确认无误后使用 kubectl apply 部署"
