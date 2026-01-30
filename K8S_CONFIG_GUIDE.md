# K8S 集群配置获取指南

本指南面向刚接手 Kubernetes 集群的用户，说明如何获取 `config.sh` 中所需的各项配置参数。

## 目录

1. [前置准备](#前置准备)
2. [节点信息](#节点信息)
3. [命名空间](#命名空间)
4. [GPU 相关](#gpu-相关)
5. [网络配置](#网络配置)
6. [存储路径](#存储路径)
7. [镜像信息](#镜像信息)
8. [资源配置](#资源配置)
9. [检查清单](#检查清单)

---

## 前置准备

### 确认 kubectl 可用

```bash
# 检查 kubectl 是否安装
kubectl version --client

# 检查能否连接到集群
kubectl cluster-info

# 查看当前上下文（确认连接的集群）
kubectl config current-context

# 查看所有可用上下文
kubectl config get-contexts
```

### 如果无法连接集群

1. 获取集群的 kubeconfig 文件（通常位于 `~/.kube/config`）
2. 或通过环境变量指定：

```bash
export KUBECONFIG=/path/to/kubeconfig.yaml
```

---

## 节点信息

### 查看所有节点

```bash
# 列出所有节点
kubectl get nodes

# 查看节点详细信息
kubectl describe node <node-name>

# 查看节点及更多标签
kubectl get nodes --show-labels
```

### 获取节点选择器 (NODE_SELECTOR)

节点选择器用于将 Pod 调度到特定节点。首先查看节点的标签：

```bash
# 查看所有节点的所有标签
kubectl get nodes --show-labels

# 查看特定节点的标签
kubectl get node <node-name> --show-labels

# 以 JSON 格式查看节点标签
kubectl get node -o jsonpath='{.items[*].metadata.labels}'
```

**常见节点标签示例：**

| 标签 Key | 说明 | 示例 Value |
|----------|------|------------|
| `gpu` | 通用 GPU 标签 | `true` |
| `node.kubernetes.io/instance-type` | 实例类型 | `p3.8xlarge` |
| `node-role.kubernetes.io/worker` | 工作节点 | `""` |
| `topology.kubernetes.io/zone` | 可用区 | `us-west-1a` |
| `nvidia.com/gpu.count` | GPU 数量 | `8` |

**如何选择合适的标签：**

```bash
# 查找带 GPU 的节点
kubectl get nodes -l nvidia.com/gpu

# 查找特定实例类型的节点
kubectl get nodes -l node.kubernetes.io/instance-type=p3.8xlarge

# 查看某个标签的所有可能值
kubectl get nodes -o jsonpath='{.items[*].metadata.labels.your-label-key}' | tr ' ' '\n' | sort -u
```

**填写 config.sh：**

```bash
# 如果节点有 gpu=true 标签
NODE_SELECTOR_KEY="gpu"
NODE_SELECTOR_VALUE="true"

# 如果使用实例类型选择
NODE_SELECTOR_KEY="node.kubernetes.io/instance-type"
NODE_SELECTOR_VALUE="p3.8xlarge"
```

### 查看节点 GPU 数量

```bash
# 方法1: 查看节点 GPU 资源总量
kubectl describe node <node-name> | grep "nvidia.com/gpu"

# 方法2: 查看所有节点的 GPU 分配情况
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu

# 方法3: 使用 jsonpath 提取
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

**填写 config.sh：**

```bash
GPU_COUNT_PER_NODE="8"  # 根据上面的查询结果填写
```

---

## 命名空间

### 查看现有命名空间

```bash
# 列出所有命名空间
kubectl get namespaces

# 或使用简写
kubectl get ns

# 查看当前默认命名空间
kubectl config view --minify -o jsonpath='{..namespace}'
```

### 创建新命名空间（可选）

```bash
# 创建测试专用命名空间
kubectl create namespace sglang-test

# 或使用 YAML 文件
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: sglang-test
EOF
```

**填写 config.sh：**

```bash
NAMESPACE="default"  # 或使用 "sglang-test" 等自定义命名空间
```

---

## GPU 相关

### 检查 GPU Device Plugin

```bash
# 检查 nvidia-device-plugin 是否运行
kubectl get pod -n kube-system | grep nvidia

# 查看 GPU 资源是否注册
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable}{"\n"}{end}' | grep gpu

# 查看 Pod 的 GPU 使用情况
kubectl get pod -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' | grep -v "<none>"
```

### 手动验证 GPU（需登录节点）

如果需要验证节点上的 GPU：

```bash
# 登录到某个 GPU 节点
ssh <node-ip>

# 查看 GPU 信息
nvidia-smi

# 查看 GPU 数量
nvidia-smi --list-gpus | wc -l

# 查看 CUDA 版本
nvcc --version
```

---

## 网络配置

NCCL 测试需要正确的网络配置，这是最容易出问题的地方。

### 获取网卡名称

```bash
# 方法1: 登录节点查看
ssh <node-ip> "ip addr show"

# 方法2: 查看 IP 地址对应的网卡
ssh <node-ip> "ip addr | grep -E '^[0-9]+:|inet '"

# 方法3: 通过 kubectl 在 Pod 中查看（如果有运行中的 Pod）
kubectl exec -it <some-pod> -- ip addr
```

**常见网卡命名规则：**

| 网卡类型 | 命名模式 | 示例 |
|----------|----------|------|
| 以太网 | `eth*`, `enp*`, `ens*` | `eth0`, `ens3np0`, `enp41s0np0` |
| InfiniBand | `ib*` | `ib0`, `ib1` |
| RoCE | `enp*` (同以太网) | `ens3np0` |

**填写 config.sh：**

```bash
# 以太网网卡（可能有多个，用逗号分隔）
NCCL_SOCKET_IFNAME="ens3np0,enp41s0np0"
GLOO_SOCKET_IFNAME="ens3np0,enp41s0np0"
```

### 获取 InfiniBand/RoCE 设备名

```bash
# 登录节点查看 IB 设备
ssh <node-ip> "ibstat" 2>/dev/null

# 查看 mlx5 设备（常见的 RDMA 网卡）
ssh <node-ip> "ls /sys/class/infiniband/"

# 查看 RDMA 设备
ssh <node-ip> "rdma link show"
```

**填写 config.sh：**

```bash
# IB 设备名（如果有 IB 网络）
NCCL_IB_HCA="mlx5_0"  # 或 "mlx5_1,mlx5_2" 如果有多个

# 如果没有 IB 网络，禁用 IB
NCCL_IB_DISABLE="1"
```

### 验证网络连通性

```bash
# 测试节点间网络（在两个节点上分别执行）
ping <other-node-ip>

# 测试 NCCL 端口（默认 13579）
telnet <other-node-ip> 13579
nc -zv <other-node-ip> 13579
```

---

## 存储路径

### 确定脚本在宿主机的位置

`scripts` 目录需要在所有 GPU 节点上可访问。

**场景 1: 脚本存储在共享存储（NFS/GlusterFS）**

```bash
# 查看已挂载的共享存储
df -h | grep -E "nfs|glusterfs|cephfs"

# 查看 PV/PVC 情况
kubectl get pv,pvc
```

**场景 2: 脚本在每个节点的相同路径**

需要将 `scripts` 目录复制到所有 GPU 节点的相同路径：

```bash
# 使用 pdsh/parallel-ssh 批量复制
pdsh -w node[1-4] "mkdir -p /path/to/k8s-env-test"
pdcp -w node[1-4] -r scripts/ /path/to/k8s-env-test/
```

**场景 3: 使用本地路径作为测试（临时）**

```bash
# 获取当前工作目录的绝对路径
pwd

# 如果在登录节点执行，注意确保 GPU 节点能访问相同路径
```

**填写 config.sh：**

```bash
# 必须填写绝对路径，且所有 GPU 节点都能访问
SCRIPTS_HOST_PATH="/shared/k8s-env-test/scripts"  # 修改为实际路径
RESULTS_HOST_PATH="/tmp/env-test-results"          # 结果输出路径
```

### 验证路径可访问性

```bash
# 在各个节点上验证路径是否存在
ssh node1 "ls -la $SCRIPTS_HOST_PATH"
ssh node2 "ls -la $SCRIPTS_HOST_PATH"

# 确保脚本有执行权限
ssh node1 "ls -l $SCRIPTS_HOST_PATH/*.sh"
```

---

## 镜像信息

### 查看现有镜像

```bash
# 查看节点上的镜像（需登录节点）
ssh <node-ip> "docker images"  # 或 "crictl images"

# 查看正在运行 Pod 使用的镜像
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u

# 查看特定镜像的 PullSecrets
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.imagePullSecrets[*].name}{"\n"}{end}'
```

### 检查镜像仓库

```bash
# 查看镜像仓库的 Secret
kubectl get secrets -A | grep registry

# 查看具体的 Secret 内容（解码）
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.dockercfg}' | base64 -d
```

**填写 config.sh：**

```bash
# 如果使用私有仓库，确保已创建 imagePullSecret
IMAGE_NAME="your-registry.com/sglang"  # 添加仓库地址
IMAGE_TAG="v0.5.7"
IMAGE_PULL_POLICY="IfNotPresent"  # 或 "Always"
```

### 创建 ImagePullSecret（如需要）

```bash
# 创建 Docker Registry Secret
kubectl create secret docker-registry regcred \
  --docker-server=<registry-url> \
  --docker-username=<username> \
  --docker-password=<password> \
  --docker-email=<email> \
  -n <namespace>

# 在 YAML 中引用
# imagePullSecrets:
#   - name: regcred
```

---

## 资源配置

### 查看节点资源总量

```bash
# 查看所有节点资源
kubectl top nodes

# 详细资源信息
kubectl describe node <node-name> | grep -A 5 "Allocated resources"

# 查看可分配资源
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\tCPU: "}{.status.allocatable.cpu}{"\tMemory: "}{.status.allocatable.memory}{"\tGPU: "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

### 查看当前资源使用

```bash
# 查看 Pod 资源使用情况
kubectl top pods -A

# 查看特定 Pod 的资源限制
kubectl get pod <pod-name> -o jsonpath='{.spec.containers[*].resources}'
```

**资源配置建议：**

| 测试类型 | CPU Request | CPU Limit | Memory Request | Memory Limit |
|----------|-------------|-----------|----------------|--------------|
| 环境检查 | 500m | 1000m | 1Gi | 2Gi |
| NCCL 测试 | 1000m | 2000m | 2Gi | 4Gi |
| NCCL 性能 | 2000m | 4000m | 4Gi | 8Gi |
| cuBLAS 测试 | 2000m | 4000m | 8Gi | 16Gi |

> 注：根据实际节点资源调整，确保所有测试 Pod 能同时调度。

---

## 检查清单

在运行测试前，确认以下配置：

### 基础检查

- [ ] `kubectl` 能正常连接集群
- [ ] `SCRIPTS_HOST_PATH` 在所有 GPU 节点上存在且可访问
- [ ] 节点标签 `NODE_SELECTOR_KEY/VALUE` 匹配实际节点
- [ ] 命名空间 `NAMESPACE` 存在或会被自动创建

### GPU 检查

- [ ] `nvidia-device-plugin` Pod 正在运行
- [ ] 节点上 GPU 资源可见 (`kubectl describe node` 显示 `nvidia.com/gpu`)
- [ ] `GPU_COUNT_PER_NODE` 配置正确

### 网络检查

- [ ] `NCCL_SOCKET_IFNAME` 网卡名称正确
- [ ] 节点间网络互通（`ping` 测试通过）
- [ ] 如使用 IB，`NCCL_IB_HCA` 配置正确
- [ ] 防火墙规则允许 NCCL 端口（默认 13579）

### 镜像检查

- [ ] 镜像 `IMAGE_NAME:IMAGE_TAG` 可访问
- [ ] 如使用私有仓库，`imagePullSecrets` 已配置

### 资源检查

- [ ] 节点有足够资源运行测试 Pod
- [ ] 资源限制不会导致调度失败

---

## 快速配置脚本

将以下命令保存为 `collect_cluster_info.sh`，一键收集集群信息：

```bash
#!/bin/bash
echo "=== K8S 集群信息收集 ==="
echo ""

echo "1. 集群基本信息:"
echo "   当前上下文: $(kubectl config current-context)"
echo "   集群地址: $(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
echo ""

echo "2. 节点信息:"
kubectl get nodes --show-labels
echo ""

echo "3. GPU 节点资源:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
echo ""

echo "4. 命名空间:"
kubectl get namespaces
echo ""

echo "5. NVIDIA Device Plugin:"
kubectl get pod -n kube-system | grep nvidia || echo "   未找到 nvidia-device-plugin"
echo ""

echo "6. 运行中的 Pod (带 GPU):"
kubectl get pods -A -o jsonpath='{range .items[?(@.spec.containers[*].resources.limits.nvidia\.com/gpu)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | head -10
echo ""

echo "7. 常用镜像:"
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u | grep -E "sglang|nvidia|cuda" | head -10
echo ""

echo "=== 建议配置 ==="
echo "NODE_SELECTOR_KEY=\"$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.gpu}' 2>/dev/null || echo 'gpu')\""
echo "NODE_SELECTOR_VALUE=\"$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.gpu}' 2>/dev/null || echo 'true')\""
echo "GPU_COUNT_PER_NODE=\"$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo '请手动填写')\""
```

使用方法：

```bash
chmod +x collect_cluster_info.sh
./collect_cluster_info.sh > cluster_info.txt
cat cluster_info.txt
```

---

## 常见问题

### Q1: 不知道集群的 kubeconfig 在哪里？

**A:** 常见位置：
- `~/.kube/config`
- 集群管理平台提供的下载链接
- 运维人员提供的配置文件

### Q2: 没有节点的 SSH 权限怎么办？

**A:** 可以通过 kubectl 创建临时 Pod 查看信息：

```bash
# 创建临时 Pod 查看网卡
kubectl run tmp-shell --image=nicolaka/netshoot --restart=Never -it --rm -- /bin/sh

# 在 Pod 内执行
ip addr
```

### Q3: 如何确定使用哪个网卡？

**A:** 选择有 IP 地址且能与其他节点通信的网卡。通常：
- 排除 `lo` (本地回环)
- 排除 `docker*`, `veth*` (容器网络)
- 选择主网卡（通常是 `eth0`, `ens*`, `enp*` 等）

### Q4: NCCL 测试一直失败？

**A:** 检查：
1. 网卡名称是否正确
2. 防火墙是否开放端口
3. 如果是 IB 网络，确认 `NCCL_IB_DISABLE=0`
4. 查看测试 Pod 日志：`kubectl logs -l app=nccl-test`
