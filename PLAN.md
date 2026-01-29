# 集群环境测试 K8S 化方案计划书

## 1. 概述

本方案旨在将现有的单机环境测试脚本转换为 Kubernetes Job/Pod 形式，支持在成百上千台机器的集群上快速执行环境验收测试，并自动收集测试报告。

## 2. 设计思路

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        测试协调器 (Coordinator)                   │
│                      (DaemonSet / 主节点 Pod)                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      测试任务队列调度                              │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Job 1:      │    │  Job 2:      │    │  Job 3:      │
│  软件栈对齐   │    │  NCCL互通测试 │    │  性能测试     │
│  (DaemonSet) │    │  (MPI Job)   │    │  (单节点)     │
└──────────────┘    └──────────────┘    └──────────────┘
```

### 2.2 镜像策略

使用现有的 `sglang:v0.5.7` 镜像作为基础镜像，该镜像已包含：
- Python 环境
- PyTorch + CUDA
- sglang 及相关依赖
- NCCL 库

额外需要的工具（如 nccl-tests、编译器）通过 init container 或 volume 注入。

## 3. K8S 任务设计

### 3.1 Job 1: 软件栈对齐检查 (DaemonSet)

**目的**：在每个节点上检查软件环境配置是否一致

**实现方式**：DaemonSet 确保每个节点运行一个 Pod

**测试内容**：
- NVIDIA 驱动版本
- Python/sglang/torch 等关键包版本
- CUDA 可用性
- 关键环境变量（NCCL 相关）
- pip freeze 输出

**输出**：每个节点生成 JSON 格式的环境报告，挂载到共享 PVC 或通过 hostPath 收集

**K8S 资源**：
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: env-check
spec:
  template:
    spec:
      containers:
      - name: checker
        image: sglang:v0.5.7
        command: ["/scripts/check_env.sh"]
```

---

### 3.2 Job 2: NCCL 节点互通测试 (MPI Job)

**目的**：验证跨节点的 NCCL 通信是否正常

**实现方式**：MPIJob（需要 Kubeflow MPI Operator）或常规 Job + hostNetwork

**测试内容**：
- 基于现有 test_allreduce.py 脚本
- 多节点 allreduce 带宽测试
- 自动发现节点 IP 并配置 MASTER_ADDR

**输出**：带宽测试结果，包含：
- World size
- Tensor size
- Elapsed time
- Effective bandwidth

**K8S 资源**（方案 A - 使用 MPIJob）：
```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-test
spec:
  slotsPerWorker: 1
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
          - image: sglang:v0.5.7
    Worker:
      replicas: N  # 节点数
      template:
        spec:
          containers:
          - image: sglang:v0.5.7
```

**K8S 资源**（方案 B - 常规 Job + hostNetwork）：
若集群无 Kubeflow，使用 StatefulSet + headless SVC 手动模拟 MPI 运行模式

---

### 3.3 Job 3: NCCL 性能测试 (单节点多卡)

**目的**：测试单机内多 GPU 的 NVLink 通信带宽

**实现方式**：Job 每台机器运行一次

**测试内容**：
- 使用 NVIDIA nccl-tests 的 all_reduce_perf
- 测试从 8M 到 1G 不同数据量的带宽
- 验证是否达到 NVLink 理论带宽（如 H200: 468 GB/s）

**输出**：
- 不同数据量的 algbw/busbw
- 平均带宽

**K8S 资源**：
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: nccl-perf-test
spec:
  completions: K  # K 台机器
  parallelism: K
  template:
    spec:
      containers:
      - name: tester
        image: sglang:v0.5.7
        command: ["/scripts/run_nccl_test.sh"]
        resources:
          limits:
            nvidia.com/gpu: 8  # 假设每机 8 卡
```

---

### 3.4 Job 4: cuBlas 算力测试 (可选)

**目的**：验证 GPU BF16 矩阵乘算力是否达到理论值

**实现方式**：Job 随机抽样部分节点测试

**测试内容**：
- 8192^3 BF16 矩阵乘
- 计算 GFLOPS 是否接近标称值（H200 ~871 TFLOPS）

**输出**：
- 平均执行时间
- 实测 GFLOPS

---

### 3.5 Job 5: 报告汇总 (可选但推荐)

**目的**：收集所有测试结果，生成统一报告

**实现方式**：Job 读取所有测试 Pod 的输出

**输出**：
- Markdown/HTML 格式的测试报告
- 包含：通过/失败状态、关键指标、异常节点列表

## 4. 实施步骤

1. **准备测试脚本**
   - 将 base_info.md 中的脚本封装为可执行文件
   - 适配容器内运行环境

2. **创建 ConfigMap/Secret**
   - 存储测试脚本
   - 配置环境变量模板

3. **编写 K8S YAML 文件**
   - DaemonSet for 环境检查
   - Job/StatefulSet for NCCL 测试
   - 报告汇总 Job

4. **测试执行脚本**
   - 一键部署所有测试 Job
   - 监控测试状态
   - 收集并展示结果

## 5. 目录结构

```
k8s-env-test/
├── scripts/
│   ├── check_env.sh           # 3.1 软件栈检查
│   ├── test_allreduce.py      # 3.2 NCCL互通测试
│   ├── launch_nccl_test.sh    # 3.2 NCCL测试启动脚本
│   ├── run_nccl_perf.sh       # 3.3 nccltest执行脚本
│   ├── test_cublas.cpp        # 3.4 cuBlas算力测试
│   └── collect_results.py     # 结果收集汇总脚本
├── k8s/
│   ├── 01-env-check-daemonset.yaml
│   ├── 02-nccl-interop-job.yaml
│   ├── 03-nccl-perf-job.yaml
│   ├── 04-cublas-job.yaml
│   ├── 05-report-job.yaml
│   └── configmap.yaml
├── README.md                  # 使用说明
└── run_all.sh                 # 一键执行脚本
```

## 6. 预期收益

1. **效率提升**：从手动逐台测试 → 一键全集群测试
2. **一致性**：所有节点使用相同测试标准
3. **可追溯**：测试结果结构化存储，便于历史对比
4. **可扩展**：新增测试项只需添加新的 Job 配置

## 7. 风险与注意事项

1. **MPI Operator 依赖**：若集群无 Kubeflow，需使用替代方案
2. **网络模式**：NCCL 测试可能需要 hostNetwork
3. **GPU 调度**：确保测试 Pod 能正确调度到 GPU 节点
4. **资源竞争**：测试期间避免与生产业务抢占 GPU
