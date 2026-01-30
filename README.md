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
├── k8s/                        # K8S 资源配置 (由 generate_yaml.sh 生成)
│   ├── 01-env-check-daemonset.yaml
│   ├── 02-nccl-interop-job.yaml
│   ├── 03-nccl-perf-job.yaml
│   ├── 04-cublas-job.yaml
│   └── 05-report-job.yaml
├── config.sh                   # 集中配置文件
├── generate_yaml.sh            # YAML 文件生成脚本
├── run_all.sh                  # 一键执行脚本
├── collect_cluster_info.sh     # 集群信息收集工具
├── PLAN.md                     # 设计计划书
├── K8S_CONFIG_GUIDE.md         # K8S 配置获取指南
└── README.md                   # 本文件
```

## 前置条件

1. **Kubernetes 集群**：已安装并配置 kubectl
2. **GPU 节点**：集群中有带 GPU 的节点，且配置了正确的标签
3. **镜像**：`sglang:v0.5.7` 镜像已可用（需包含 PyTorch、CUDA、sglang）

> **提示**：如果你刚接手集群，不熟悉如何获取集群配置信息，可以：
> - 运行 `./collect_cluster_info.sh` 自动收集集群信息
> - 参考 [K8S_CONFIG_GUIDE.md](K8S_CONFIG_GUIDE.md) 了解如何获取各项配置参数

## 快速开始

### 1. 收集集群信息（可选）

如果你刚接手集群，可以先运行信息收集脚本了解集群环境：

```bash
chmod +x collect_cluster_info.sh
./collect_cluster_info.sh
```

该脚本会输出：
- 节点列表和标签
- GPU 资源情况
- 命名空间信息
- 建议的配置参数

### 2. 配置参数

根据收集的信息，编辑 `config.sh` 文件：

```bash
# === 基础配置 ===
NAMESPACE="default"                 # Kubernetes 命名空间

# === 路径配置 ===
SCRIPTS_HOST_PATH="/path/to/k8s-env-test/scripts"  # 修改为实际路径！
RESULTS_HOST_PATH="/tmp/env-test-results"          # 结果输出路径

# === 节点选择 ===
NODE_SELECTOR_KEY="gpu"             # 节点标签的 key
NODE_SELECTOR_VALUE="true"          # 节点标签的 value

# === GPU 配置 ===
GPU_COUNT_PER_NODE="8"              # 每节点 GPU 数量

# === NCCL 网络配置 ===
NCCL_SOCKET_IFNAME="ens3np0,enp41s0np0"     # 以太网网卡名
NCCL_IB_HCA="mlx5_0"                         # InfiniBand 设备名

# === 测试节点配置 ===
NCCL_TEST_REPLICAS="2"               # NCCL 互通测试的节点数
NCCL_PERF_REPLICAS="2"               # NCCL 性能测试的节点数
CUBLAS_REPLICAS="1"                  # cuBLAS 测试的节点数

# === 镜像配置 ===
IMAGE_NAME="sglang"
IMAGE_TAG="v0.5.7"
```

> 详细的配置说明请参考：[K8S_CONFIG_GUIDE.md](K8S_CONFIG_GUIDE.md)

### 3. 生成 YAML 文件

配置完成后，运行生成脚本：

```bash
./generate_yaml.sh
```

这会根据 `config.sh` 的配置自动生成 `k8s/` 目录下的所有 YAML 文件。

### 4. 执行测试

```bash
# 基础用法
./run_all.sh

# 自定义参数
./run_all.sh --nodes 4 --namespace sglang-test --cleanup

# 跳过某些测试
./run_all.sh --skip-cublas --skip-perf
```

**run_all.sh 支持的参数：**

| 参数 | 说明 |
|------|------|
| `--skip-env` | 跳过环境检查 |
| `--skip-nccl` | 跳过 NCCL 测试 |
| `--skip-perf` | 跳过性能测试 |
| `--skip-cublas` | 跳过 cuBLAS 测试 |
| `--nodes N` | 设置节点数 (默认: 2) |
| `--namespace NS` | 设置命名空间 (默认: default) |
| `--scripts-path` | 脚本路径 |
| `--results-path` | 结果路径 |
| `--cleanup` | 测试完成后清理资源 |
| `-h, --help` | 显示帮助 |

### 5. 查看结果

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

### Job 2: NCCL 节点互通测试 (StatefulSet)

使用 StatefulSet 实现多节点 NCCL 通信测试：
- 多节点 AllReduce 带宽测试
- 验证 RDMA/IB 连通性
- 通过 Headless Service 实现 Pod 间服务发现

**输出**：`nccl_allreduce_rank<rank>.json`

### Job 3: NCCL 性能测试 (Job)

使用 NVIDIA nccl-tests 测试单机多卡性能：
- 不同数据量的 AllReduce 带宽
- 验证 NVLink 理论带宽
- 通过 initContainer 自动编译 nccl-tests

**输出**：`nccl_perf_<node_name>.json`

### Job 4: cuBLAS 算力测试 (Job)

测试 GPU BF16 矩阵乘算力：
- 8192x8192 矩阵乘
- 对比标称算力值
- 通过 initContainer 自动编译测试程序

**输出**：`cublas_test_<node_name>.json`

### Job 5: 报告汇总 (Job)

收集所有测试结果，生成统一报告

**输出**：`test_report.json`, `test_report.md`

## 手动执行单个测试

```bash
# 仅环境检查
kubectl apply -f k8s/01-env-check-daemonset.yaml

# 仅 NCCL 互通测试 (StatefulSet + Headless Service)
kubectl apply -f k8s/02-nccl-interop-job.yaml

# 仅 NCCL 性能测试
kubectl apply -f k8s/03-nccl-perf-job.yaml

# 仅 cuBLAS 测试
kubectl apply -f k8s/04-cublas-job.yaml

# 仅报告汇总
kubectl apply -f k8s/05-report-job.yaml

# 查看日志
kubectl logs -l app=env-check --namespace=default
kubectl logs -l app=nccl-test --namespace=default
kubectl logs -l app=nccl-perf-test --namespace=default
kubectl logs -l app=cublas-test --namespace=default
```

## 配置说明

### config.sh 配置项

| 配置项 | 说明 |
|--------|------|
| `NAMESPACE` | Kubernetes 命名空间 |
| `SCRIPTS_HOST_PATH` | 脚本在宿主机上的绝对路径（必须正确配置） |
| `RESULTS_HOST_PATH` | 测试结果输出路径 |
| `NODE_SELECTOR_KEY/VALUE` | 节点选择器标签 |
| `GPU_COUNT_PER_NODE` | 每节点 GPU 数量 |
| `NCCL_SOCKET_IFNAME` | 以太网网卡名（逗号分隔） |
| `NCCL_IB_HCA` | InfiniBand 设备名 |
| `NCCL_IB_DISABLE` | 是否禁用 IB (0=启用, 1=禁用) |
| `IMAGE_NAME/TAG` | 测试容器镜像 |
| `*_REPLICAS` | 各测试的副本/节点数 |
| `_*_REQUEST/LIMIT` | 资源限制配置 |

### 修改配置后重新生成 YAML

每次修改 `config.sh` 后，需要重新运行：

```bash
./generate_yaml.sh
```

这会覆盖 `k8s/` 目录下的现有 YAML 文件。

## 故障排查

### 1. Pod 无法调度

检查节点标签是否正确：
```bash
kubectl get nodes --show-labels
```

确认 `config.sh` 中的 `NODE_SELECTOR_KEY` 和 `NODE_SELECTOR_VALUE` 与集群标签匹配。

### 2. GPU 不可用

检查 nvidia-device-plugin 是否运行：
```bash
kubectl get pod -n kube-system | grep nvidia
```

### 3. NCCL 测试失败

- 检查 `NCCL_SOCKET_IFNAME` 网卡名称是否正确
- 检查防火墙规则是否放行 NCCL 端口
- 确认 IB 网卡配置 (`NCCL_IB_HCA`)
- 查看 StatefulSet Pod 日志排查具体错误

### 4. 结果文件为空

检查 hostPath 挂载是否正确：
```bash
kubectl exec -it <pod-name> -- ls -la /results
```

确认 `SCRIPTS_HOST_PATH` 和 `RESULTS_HOST_PATH` 配置正确。

### 5. initContainer 编译失败

如果 nccl-tests 或 cuBLAS 测试编译失败：
- 检查网络连接（需要访问 GitHub）
- 检查 CUDA 开发镜像是否可用
- 查看具体 Pod 的 initContainer 日志

## 清理资源

```bash
# 删除所有测试资源
kubectl delete -f k8s/ --namespace=default

# 或使用脚本自动清理
./run_all.sh --cleanup
```

## 许可

本项目仅供内部使用。
