#!/usr/bin/env python3
"""
NCCL AllReduce 互通测试
用于验证跨节点的 NCCL 通信是否正常
"""

import os
import time
import json
import torch
import torch.distributed as dist


def main():
    # -------- 基本检查 --------
    if not torch.cuda.is_available():
        print(json.dumps({"error": "CUDA not available"}))
        return 1

    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    local_rank = int(os.environ.get("LOCAL_RANK", 0))

    torch.cuda.set_device(local_rank)

    # -------- 初始化 NCCL --------
    dist.init_process_group(
        backend="nccl",
        init_method="env://",
    )

    device = torch.device("cuda", local_rank)

    # -------- 创建大 tensor（用于测带宽）--------
    # 256MB tensor（可调到 512MB / 1GB）
    num_elems = 1024 * 1024 * 1024 // 4
    tensor = torch.ones(num_elems, device=device)

    # -------- warmup --------
    for _ in range(5):
        dist.all_reduce(tensor)
    torch.cuda.synchronize()

    # -------- 正式测试 --------
    iters = 20
    start = time.time()
    for _ in range(iters):
        dist.all_reduce(tensor)
    torch.cuda.synchronize()
    elapsed = time.time() - start

    # -------- 计算带宽 --------
    bytes_transferred = tensor.numel() * tensor.element_size()
    # all-reduce 等价通信量：2*(N-1)/N
    bw = (bytes_transferred * iters * 2 * (world_size - 1) / world_size) / elapsed
    bw_gbps = bw / 1e9

    result = {
        "test": "nccl_allreduce",
        "world_size": world_size,
        "rank": rank,
        "local_rank": local_rank,
        "tensor_size_mb": bytes_transferred / 1e6,
        "tensor_size_bytes": bytes_transferred,
        "iterations": iters,
        "elapsed_time_s": round(elapsed, 3),
        "bandwidth_gbps": round(bw_gbps, 2),
        "status": "success"
    }

    # 获取节点信息
    result["node_name"] = os.environ.get("NODE_NAME", os.uname().nodename)
    result["master_addr"] = os.environ.get("MASTER_ADDR", "unknown")

    # 保存结果
    output_dir = os.environ.get("OUTPUT_DIR", "/results")
    os.makedirs(output_dir, exist_ok=True)
    output_file = os.path.join(output_dir, f"nccl_allreduce_rank{rank}.json")
    with open(output_file, "w") as f:
        json.dump(result, f, indent=2)

    # Rank 0 打印汇总
    if rank == 0:
        print("\n=== NCCL AllReduce Result ===")
        print(f"World size      : {world_size}")
        print(f"Tensor size     : {bytes_transferred / 1e6:.1f} MB")
        print(f"Iterations      : {iters}")
        print(f"Elapsed time    : {elapsed:.3f} s")
        print(f"Effective BW    : {bw_gbps:.2f} GB/s")
        print(f"\n结果已保存到: {output_file}")

    dist.destroy_process_group()
    return 0


if __name__ == "__main__":
    exit(main())
