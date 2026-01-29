#!/usr/bin/env python3
"""
结果收集与汇总脚本
读取所有测试结果并生成统一的测试报告
"""

import os
import json
import glob
from datetime import datetime
from pathlib import Path


def load_json(filepath):
    """加载 JSON 文件"""
    try:
        with open(filepath, "r") as f:
            return json.load(f)
    except Exception as e:
        return {"error": str(e), "file": str(filepath)}


def summarize_env_checks(results_dir):
    """汇总环境检查结果"""
    pattern = os.path.join(results_dir, "env_check_*.json")
    files = glob.glob(pattern)

    if not files:
        return {"status": "no_results", "nodes": []}

    nodes = []
    issues = []

    for f in files:
        data = load_json(f)
        node_name = data.get("node_name", "unknown")
        nodes.append({
            "name": node_name,
            "gpu_count": data.get("gpu_count", 0),
            "driver_version": data.get("nvidia_driver_version", "unknown"),
            "cuda_version": data.get("cuda_version", "unknown"),
            "python_version": data.get("python_version", "unknown"),
            "torch_version": data.get("torch_details", {}).get("torch_version", "unknown"),
            "cuda_available": data.get("torch_details", {}).get("cuda_available", False),
            "checks": data.get("checks", {})
        })

        # 检查问题
        checks = data.get("checks", {})
        if checks.get("nvidia_smi") == "fail":
            issues.append(f"{node_name}: nvidia-smi 不可用")
        if checks.get("cuda_available") == "fail":
            issues.append(f"{node_name}: CUDA 不可用")
        if checks.get("sglang_import") == "fail":
            issues.append(f"{node_name}: sglang 导入失败")

    # 检查版本一致性
    driver_versions = set(n["driver_version"] for n in nodes if n["driver_version"] != "unknown")
    cuda_versions = set(n["cuda_version"] for n in nodes if n["cuda_version"] != "unknown")
    torch_versions = set(n["torch_version"] for n in nodes if n["torch_version"] != "unknown")

    return {
        "status": "success" if not issues else "warning",
        "total_nodes": len(nodes),
        "nodes": nodes,
        "issues": issues,
        "consistency": {
            "driver_consistent": len(driver_versions) <= 1,
            "cuda_consistent": len(cuda_versions) <= 1,
            "torch_consistent": len(torch_versions) <= 1,
            "driver_versions": list(driver_versions),
            "cuda_versions": list(cuda_versions),
            "torch_versions": list(torch_versions),
        }
    }


def summarize_nccl_allreduce(results_dir):
    """汇总 NCCL AllReduce 结果"""
    pattern = os.path.join(results_dir, "nccl_allreduce_*.json")
    files = glob.glob(pattern)

    if not files:
        return {"status": "no_results"}

    results = []
    for f in files:
        data = load_json(f)
        results.append(data)

    # 取 rank 0 的结果作为代表
    rank0 = next((r for r in results if r.get("rank") == 0), results[0] if results else {})

    return {
        "status": "success",
        "world_size": rank0.get("world_size", len(results)),
        "bandwidth_gbps": rank0.get("bandwidth_gbps", 0),
        "elapsed_time_s": rank0.get("elapsed_time_s", 0),
        "tensor_size_mb": rank0.get("tensor_size_mb", 0),
        "details": results
    }


def summarize_nccl_perf(results_dir):
    """汇总 NCCL 性能测试结果"""
    pattern = os.path.join(results_dir, "nccl_perf_*.json")
    files = glob.glob(pattern)

    if not files:
        return {"status": "no_results"}

    nodes = []
    for f in files:
        data = load_json(f)
        nodes.append({
            "node": data.get("node_name", "unknown"),
            "avg_bandwidth_gbps": data.get("avg_bus_bandwidth_gbps", 0),
            "results": data.get("results", [])
        })

    # 计算平均带宽
    avg_bandwidths = [n["avg_bandwidth_gbps"] for n in nodes if n["avg_bandwidth_gbps"] > 0]
    overall_avg = sum(avg_bandwidths) / len(avg_bandwidths) if avg_bandwidths else 0

    return {
        "status": "success",
        "total_nodes": len(nodes),
        "overall_avg_bandwidth_gbps": round(overall_avg, 2),
        "nodes": nodes
    }


def summarize_cublas(results_dir):
    """汇总 cuBLAS 测试结果"""
    pattern = os.path.join(results_dir, "cublas_test_*.json")
    files = glob.glob(pattern)

    if not files:
        return {"status": "no_results"}

    nodes = []
    for f in files:
        data = load_json(f)
        nodes.append({
            "node": data.get("node_name", "unknown"),
            "matrix_size": data.get("matrix_size", "unknown"),
            "avg_time_ms": data.get("avg_time_ms", 0),
            "tflops": data.get("tflops", 0)
        })

    return {
        "status": "success",
        "total_nodes": len(nodes),
        "nodes": nodes
    }


def generate_report(results_dir):
    """生成完整报告"""
    report = {
        "generated_at": datetime.now().isoformat(),
        "summary": {},
        "details": {}
    }

    # 各项测试结果
    env_check = summarize_env_checks(results_dir)
    nccl_allreduce = summarize_nccl_allreduce(results_dir)
    nccl_perf = summarize_nccl_perf(results_dir)
    cublas = summarize_cublas(results_dir)

    report["details"]["env_check"] = env_check
    report["details"]["nccl_allreduce"] = nccl_allreduce
    report["details"]["nccl_perf"] = nccl_perf
    report["details"]["cublas"] = cublas

    # 汇总状态
    all_status = []
    issues = []

    if env_check.get("status") == "success":
        all_status.append("env_check: PASS")
    else:
        all_status.append(f"env_check: {env_check.get('status', 'UNKNOWN').upper()}")
        issues.extend(env_check.get("issues", []))

    if nccl_allreduce.get("status") == "success":
        all_status.append("nccl_allreduce: PASS")
    else:
        all_status.append(f"nccl_allreduce: {nccl_allreduce.get('status', 'UNKNOWN').upper()}")

    if nccl_perf.get("status") == "success":
        all_status.append("nccl_perf: PASS")
    else:
        all_status.append(f"nccl_perf: {nccl_perf.get('status', 'UNKNOWN').upper()}")

    if cublas.get("status") == "success":
        all_status.append("cublas: PASS")
    else:
        all_status.append(f"cublas: {cublas.get('status', 'UNKNOWN').upper()}")

    report["summary"]["overall_status"] = "PASS" if not any("FAIL" in s or "WARNING" in s for s in all_status) else "WARNING"
    report["summary"]["test_status"] = all_status
    report["summary"]["issues"] = issues

    return report


def print_markdown_report(report):
    """打印 Markdown 格式报告"""
    print("\n" + "=" * 60)
    print("集群环境测试报告")
    print("=" * 60)
    print(f"生成时间: {report['generated_at']}")
    print(f"总体状态: {report['summary']['overall_status']}")
    print()

    print("## 测试状态")
    for status in report['summary']['test_status']:
        print(f"  - {status}")
    print()

    if report['summary']['issues']:
        print("## 发现的问题")
        for issue in report['summary']['issues']:
            print(f"  - {issue}")
        print()

    # 环境检查详情
    env = report['details']['env_check']
    if env.get('status') != 'no_results':
        print("## 环境检查")
        print(f"  检测节点数: {env['total_nodes']}")
        print(f"  驱动版本一致性: {'是' if env['consistency']['driver_consistent'] else '否'}")
        print(f"  CUDA 版本一致性: {'是' if env['consistency']['cuda_consistent'] else '否'}")
        print(f"  Torch 版本一致性: {'是' if env['consistency']['torch_consistent'] else '否'}")
        if env['consistency']['driver_versions']:
            print(f"  驱动版本: {', '.join(env['consistency']['driver_versions'])}")
        if env['consistency']['cuda_versions']:
            print(f"  CUDA 版本: {', '.join(env['consistency']['cuda_versions'])}")
        if env['consistency']['torch_versions']:
            print(f"  Torch 版本: {', '.join(env['consistency']['torch_versions'])}")
        print()

    # NCCL AllReduce 详情
    nccl = report['details']['nccl_allreduce']
    if nccl.get('status') == 'success':
        print("## NCCL 节点互通测试")
        print(f"  节点数: {nccl['world_size']}")
        print(f"  有效带宽: {nccl['bandwidth_gbps']:.2f} GB/s")
        print()

    # NCCL 性能详情
    perf = report['details']['nccl_perf']
    if perf.get('status') == 'success':
        print("## NCCL 性能测试")
        print(f"  测试节点数: {perf['total_nodes']}")
        print(f"  平均带宽: {perf['overall_avg_bandwidth_gbps']:.2f} GB/s")
        for node in perf['nodes']:
            print(f"    - {node['node']}: {node['avg_bandwidth_gbps']:.2f} GB/s")
        print()

    # cuBLAS 详情
    cublas = report['details']['cublas']
    if cublas.get('status') == 'success':
        print("## cuBLAS 算力测试")
        print(f"  测试节点数: {cublas['total_nodes']}")
        for node in cublas['nodes']:
            print(f"    - {node['node']}: {node['tflops']:.1f} TFLOPS")
        print()

    print("=" * 60)


def main():
    results_dir = os.environ.get("RESULTS_DIR", "/results")
    output_file = os.environ.get("OUTPUT_FILE", os.path.join(results_dir, "test_report.json"))

    print("=== 收集测试结果 ===")
    print(f"结果目录: {results_dir}")

    # 列出所有结果文件
    all_files = glob.glob(os.path.join(results_dir, "*.json"))
    print(f"找到 {len(all_files)} 个结果文件")

    # 生成报告
    report = generate_report(results_dir)

    # 保存 JSON 报告
    with open(output_file, "w") as f:
        json.dump(report, f, indent=2)
    print(f"JSON 报告已保存到: {output_file}")

    # 打印 Markdown 报告
    print_markdown_report(report)

    # 保存 Markdown 报告
    md_file = output_file.replace(".json", ".md")
    with open(md_file, "w") as f:
        f.write("# 集群环境测试报告\n\n")
        f.write(f"生成时间: {report['generated_at']}\n\n")
        f.write(f"总体状态: {report['summary']['overall_status']}\n\n")
        # ... (更多 Markdown 内容)
    print(f"Markdown 报告已保存到: {md_file}")

    return 0 if report['summary']['overall_status'] == 'PASS' else 1


if __name__ == "__main__":
    exit(main())
