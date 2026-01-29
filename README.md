# K8S 集群环境测试工具

用于在 Kubernetes 集群上快速执行 sglang 部署前的环境验收测试。

## 项目结构

```
k8s-env-test/
├── scripts/                    # 测试脚本目录
│   ├── check_env.sh           # 环境检查 (驱动、CUDA、Python、sglang)
│   ├── test_allreduce.py      # NCCL AllReduce 测试
│   ├── launch_nccl_test.sh    # NCCL 测试启动脚本
│   ├── run_nccl_perf.sh       # nccl-tests 性能测试
│   ├── test_cublas.cpp        # cuBLAS 算力测试源码
│   ├── run_cublas_test.sh     # cuBLAS 测试启动脚本
│   └── collect_results.py     # 结果收集汇总
├── k8s/                        # K8S 资源配置
│   ├── 01-env-check-daemonset.yaml
│   ├── 02-nccl-interop-job.yaml
│   ├── 03-nccl-perf-job.yaml
│   ├── 04-cublas-job.yaml
│   ├── 05-report-job.yaml
│   └── configmap.yaml
├── run_all.sh                  # 一键执行脚本
├── PLAN.md                     # 设计计划书
└── README.md                   # 本文件
```

## 前置条件

1. **Kubernetes 集群**：已安装并配置 kubectl
2. **GPU 节点**：集群中有带 GPU 的节点，且配置了正确的标签
3. **镜像**：`sglang:v0.5.7` 镜像已可用（需包含 PyTorch、CUDA、sglang）

## 快速开始

### 1. 修改配置

编辑 K8S YAML 文件，修改以下路径为实际值：

```yaml
# 在每个 YAML 文件中
volumes:
  - name: scripts
    hostPath:
      path: /path/to/k8s-env-test/scripts  # 修改为实际路径
  - name: results
    hostPath:
      path: /tmp/env-test-results  # 或改为使用 PVC
```

修改节点选择器以匹配你的集群：

```yaml
nodeSelector:
  gpu: "true"  # 修改为实际的节点标签
```

修改网络配置（NCCL 测试）：

```yaml
env:
  - name: NCCL_SOCKET_IFNAME
    value: "ens3np0,enp41s0np0"  # 修改为实际网卡名
  - name: NCCL_IB_HCA
    value: "mlx5_0"  # 修改为实际 IB 设备名
```

### 2. 执行测试

```bash
# 基础用法
./run_all.sh

# 自定义参数
./run_all.sh --nodes 4 --namespace sglang-test --cleanup

# 跳过某些测试
./run_all.sh --skip-cublas --skip-perf
```

### 3. 查看结果

测试完成后，结果会保存在当前目录：

- `test_report.json` - JSON 格式的详细报告
- `test_report.md` - Markdown 格式的可读报告

## 各测试项说明

### Job 1: 环境检查 (DaemonSet)

在每个 GPU 节点上运行，检查：
- NVIDIA 驱动版本
- CUDA 版本
- Python 和关键包版本
- CUDA 可用性
- 关键环境变量

**输出**：`env_check_<node_name>.json`

### Job 2: NCCL 节点互通测试

测试跨节点的 NCCL 通信：
- 多节点 AllReduce 带宽测试
- 验证 RDMA/IB 连通性

**注意事项**：需要手动配置 MASTER_ADDR，或使用 Service 自动发现

**输出**：`nccl_allreduce_rank<rank>.json`

### Job 3: NCCL 性能测试

使用 NVIDIA nccl-tests 测试单机多卡性能：
- 不同数据量的 AllReduce 带宽
- 验证 NVLink 理论带宽

**输出**：`nccl_perf_<node_name>.json`

### Job 4: cuBLAS 算力测试

测试 GPU BF16 矩阵乘算力：
- 8192^3 矩阵乘
- 对比标称算力值

**输出**：`cublas_test_<node_name>.json`

### Job 5: 报告汇总

收集所有测试结果，生成统一报告

**输出**：`test_report.json`, `test_report.md`

## 手动执行单个测试

```bash
# 仅环境检查
kubectl apply -f k8s/01-env-check-daemonset.yaml

# 仅 NCCL 性能测试
kubectl apply -f k8s/03-nccl-perf-job.yaml

# 查看日志
kubectl logs -l app=env-check --namespace=default
```

## 故障排查

### 1. Pod 无法调度

检查节点标签是否正确：
```bash
kubectl get nodes --show-labels
```

### 2. GPU 不可用

检查 nvidia-device-plugin 是否运行：
```bash
kubectl get pod -n kube-system | grep nvidia
```

### 3. NCCL 测试失败

- 检查网卡名称是否正确
- 检查防火墙规则
- 确认 IB 网卡配置

### 4. 结果文件为空

检查 hostPath 挂载是否正确：
```bash
kubectl exec -it <pod-name> -- ls -la /results
```

## 清理资源

```bash
# 删除所有测试资源
kubectl delete -f k8s/ --namespace=default

# 或使用脚本自动清理
./run_all.sh --cleanup
```

## 许可

本项目仅供内部使用。
