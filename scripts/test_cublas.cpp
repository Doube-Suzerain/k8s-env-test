/**
 * cuBLAS 算力测试
 * 测试 H200 BF16 矩阵乘算力峰值
 * 编译: nvcc test_cublas.cpp -o test_cublas -lcublasLt -lcublas -lcudart -std=c++17
 */

#include <iostream>
#include <vector>
#include <cuda_runtime.h>
#include <cublasLt.h>
#include <cublas_v2.h>
#include <chrono>
#include <iomanip>

#define CHECK_CUDA(x) do { if((x)!=cudaSuccess){ \
    std::cerr << "CUDA Error " << __FILE__ << ":" << __LINE__ << " : " << cudaGetErrorString(x) << std::endl; exit(1);}} while(0)
#define CHECK_CUBLAS(x) do { if((x)!=CUBLAS_STATUS_SUCCESS){ \
    std::cerr << "CUBLAS Error " << __FILE__ << ":" << __LINE__ << std::endl; exit(1);}} while(0)

int main(int argc, char* argv[]) {
    int M = 8192, N = 8192, K = 8192;

    // 可选：从命令行参数读取矩阵大小
    if (argc >= 4) {
        M = std::atoi(argv[1]);
        N = std::atoi(argv[2]);
        K = std::atoi(argv[3]);
    }

    int device_id = 0;
    if (argc >= 5) {
        device_id = std::atoi(argv[4]);
    }
    CHECK_CUDA(cudaSetDevice(device_id));

    cublasLtHandle_t ltHandle;
    CHECK_CUBLAS(cublasLtCreate(&ltHandle));

    __nv_bfloat16 *d_A, *d_B, *d_C;
    CHECK_CUDA(cudaMalloc(&d_A, M*K*sizeof(__nv_bfloat16)));
    CHECK_CUDA(cudaMalloc(&d_B, K*N*sizeof(__nv_bfloat16)));
    CHECK_CUDA(cudaMalloc(&d_C, M*N*sizeof(__nv_bfloat16)));

    // 初始化 host 数据
    std::vector<__nv_bfloat16> h_A(M*K), h_B(K*N);
    for (int i=0;i<M*K;i++) h_A[i]=__float2bfloat16((float)rand()/RAND_MAX);
    for (int i=0;i<K*N;i++) h_B[i]=__float2bfloat16((float)rand()/RAND_MAX);
    CHECK_CUDA(cudaMemcpy(d_A, h_A.data(), M*K*sizeof(__nv_bfloat16), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_B, h_B.data(), K*N*sizeof(__nv_bfloat16), cudaMemcpyHostToDevice));

    __nv_bfloat16 alpha = __float2bfloat16(1.0f);
    __nv_bfloat16 beta  = __float2bfloat16(0.0f);

    cublasLtMatmulDesc_t operationDesc;
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;

    CHECK_CUBLAS(cublasLtMatmulDescCreate(&operationDesc, CUBLAS_COMPUTE_32F, CUDA_R_32F));

    cublasOperation_t opA = CUBLAS_OP_N;
    cublasOperation_t opB = CUBLAS_OP_N;
    CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSA, &opA, sizeof(opA)));
    CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSB, &opB, sizeof(opB)));

    CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_16BF, M, K, M));
    CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_16BF, K, N, K));
    CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_16BF, M, N, M));

    // preference 对象
    cublasLtMatmulPreference_t preference;
    CHECK_CUBLAS(cublasLtMatmulPreferenceCreate(&preference));

    cublasLtMatmulHeuristicResult_t heuristicResult;
    int returnedResults = 0;
    CHECK_CUBLAS(cublasLtMatmulAlgoGetHeuristic(
        ltHandle,
        operationDesc,
        Adesc, Bdesc, Cdesc, Cdesc,
        preference,
        1,
        &heuristicResult,
        &returnedResults
    ));

    // warm-up
    for (int i=0; i<5; i++) {
        CHECK_CUBLAS(cublasLtMatmul(
            ltHandle,
            operationDesc,
            &alpha,
            d_A, Adesc,
            d_B, Bdesc,
            &beta,
            d_C, Cdesc,
            d_C, Cdesc,
            &heuristicResult.algo,
            nullptr, 0, 0
        ));
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // 测性能
    int iterations = 20;
    auto start = std::chrono::high_resolution_clock::now();
    for (int i=0;i<iterations;i++) {
        CHECK_CUBLAS(cublasLtMatmul(
            ltHandle,
            operationDesc,
            &alpha,
            d_A, Adesc,
            d_B, Bdesc,
            &beta,
            d_C, Cdesc,
            d_C, Cdesc,
            &heuristicResult.algo,
            nullptr, 0, 0
        ));
    }
    CHECK_CUDA(cudaDeviceSynchronize());
    auto end = std::chrono::high_resolution_clock::now();
    double timeMs = std::chrono::duration<double, std::milli>(end - start).count()/iterations;
    double gflops = 2.0 * M * N * K / (timeMs * 1e6);
    double tflops = gflops / 1000.0;

    // 输出结果（JSON 格式）
    std::cout << "{" << std::endl;
    std::cout << "  \"test\": \"cublas_matmul\"," << std::endl;
    std::cout << "  \"matrix_size\": \"" << M << "x" << N << "x" << K << "\"," << std::endl;
    std::cout << "  \"data_type\": \"bfloat16\"," << std::endl;
    std::cout << "  \"iterations\": " << iterations << "," << std::endl;
    std::cout << "  \"avg_time_ms\": " << std::fixed << std::setprecision(5) << timeMs << "," << std::endl;
    std::cout << "  \"gflops\": " << std::fixed << std::setprecision(3) << gflops << "," << std::endl;
    std::cout << "  \"tflops\": " << std::fixed << std::setprecision(3) << tflops << "," << std::endl;
    std::cout << "  \"status\": \"success\"" << std::endl;
    std::cout << "}" << std::endl;

    // 清理
    cublasLtMatmulPreferenceDestroy(preference);
    cublasLtMatmulDescDestroy(operationDesc);
    cublasLtMatrixLayoutDestroy(Adesc);
    cublasLtMatrixLayoutDestroy(Bdesc);
    cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtDestroy(ltHandle);
    cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);

    return 0;
}
