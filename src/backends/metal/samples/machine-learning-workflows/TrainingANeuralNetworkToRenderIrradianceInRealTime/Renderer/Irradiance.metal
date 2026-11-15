/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Metal kernels for the three irradiance techniques and the cooperative matmul MLP training routines, including the Adam optimizer step.
*/

#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MPPTensorOpsMatMul2d.h>
#import "ShaderTypes.h"

// Irradiance computation via three techniques (Monte Carlo, MLP inference, ML pipeline), plus
// GPU-resident MLP training using cooperative matmul2d for both forward and backward passes,
// with Adam as the optimizer.

using namespace metal;
using namespace mpp::tensor_ops;

#pragma mark - Monte Carlo helpers

static float radicalInverse(uint bits)
{
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

static float2 hammersley(uint i, uint N)
{
    return float2(float(i) / float(N), radicalInverse(i));
}

static float3 cosineSampleHemisphere(float2 xi)
{
    float cosTheta = sqrt(1.0 - xi.y);
    float sinTheta = sqrt(xi.y);
    float phi = 2.0 * M_PI_F * xi.x;
    return float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

static float3 evaluateMonteCarloGI(float3 worldNormal, texture2d<float> envMap,
                                    sampler texSampler, uint numSamples = 64)
{
    float3 up = abs(worldNormal.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, worldNormal));
    float3 bitangent = cross(worldNormal, tangent);

    float3 irradiance = float3(0);
    for (uint i = 0; i < numSamples; i++) {
        float2 xi = hammersley(i, numSamples);
        float3 localDir = cosineSampleHemisphere(xi);
        float3 sampleDir = localDir.x * tangent + localDir.y * bitangent + localDir.z * worldNormal;
        float2 sUV = directionToEquirectangular(sampleDir);
        irradiance += min(envMap.sample(texSampler, sUV).rgb, float3(10.0f));
    }
    return irradiance * (M_PI_F / float(numSamples));
}

#pragma mark - MLP inference

static constant int PIXEL_BATCH_SIZE = 32;
static constant int THREADGROUP_SIZE = 16 * 16;
static constant int NUM_INPUT  = 16;
static constant int NUM_HIDDEN = 16;
static constant int MLP_OUTPUT = 8;

static constant half LEAKY_ALPHA_H = 0.01h;

template<typename CoopTensor>
static void applyBiasLeakyReLU(thread CoopTensor &coop, const device half *bias)
{
    simdgroup_barrier(mem_flags::mem_none);
    for (uint16_t i = 0; i < coop.get_capacity(); ++i) {
        int col = coop.get_multidimensional_index(i)[0];
        half v = coop[i] + bias[col];
        coop[i] = v > 0.0h ? v : LEAKY_ALPHA_H * v;
    }
}

template<bool StoreScratch>
tensor<threadgroup half, extents<int, MLP_OUTPUT, PIXEL_BATCH_SIZE>, metal::tensor_inline>
mlpInference(uint lane, half3 normal,
             tensor<device half, extents<int, NUM_INPUT, NUM_HIDDEN>> layer0Weights,
             tensor<device half, extents<int, NUM_HIDDEN, NUM_HIDDEN>> layer1Weights,
             tensor<device half, extents<int, NUM_HIDDEN, MLP_OUTPUT>> layer2Weights,
             const device half *b0, const device half *b1, const device half *b2,
             threadgroup half *scratch, threadgroup half *smem_a0, threadgroup half *smem_a1)
{
    constexpr auto inputToHiddenDesc = matmul2d_descriptor(PIXEL_BATCH_SIZE, NUM_HIDDEN, NUM_INPUT, false, true, true);
    matmul2d<inputToHiddenDesc, execution_simdgroup> inputToHiddenOp;

    auto inputMatrix = tensor(scratch, extents<int, NUM_INPUT, PIXEL_BATCH_SIZE>());
    inputMatrix.set(normal, 0, lane);
    for (int i = 3; i < NUM_INPUT; i++)
        inputMatrix.set(0.0h, i, lane);
    simdgroup_barrier(mem_flags::mem_threadgroup);

    auto hiddenDst0 = inputToHiddenOp.get_destination_cooperative_tensor<decltype(inputMatrix), decltype(layer0Weights), half>();
    inputToHiddenOp.run(inputMatrix, layer0Weights, hiddenDst0);
    applyBiasLeakyReLU(hiddenDst0, b0);

    constexpr auto hiddenToHiddenDesc = matmul2d_descriptor(PIXEL_BATCH_SIZE, NUM_HIDDEN, NUM_HIDDEN, false, true, true);
    matmul2d<hiddenToHiddenDesc, execution_simdgroup> hiddenToHiddenOp;

    const bool layer1Compatible = hiddenToHiddenOp.is_compatible_as_left_input<half, half, half>(hiddenDst0);
    auto layer1Input = layer1Compatible
        ? hiddenToHiddenOp.get_left_input_cooperative_tensor<half, half, half>(hiddenDst0)
        : hiddenToHiddenOp.get_left_input_cooperative_tensor<half, half, half>();
    using HiddenTensor = tensor<threadgroup half, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>, tensor_inline>;
    HiddenTensor a0Mat;
    if (StoreScratch || !layer1Compatible) {
        a0Mat = tensor(smem_a0, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
        hiddenDst0.store(a0Mat);
        simdgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!layer1Compatible) {
        layer1Input.load(a0Mat);
        simdgroup_barrier(mem_flags::mem_none);
    }

    auto hiddenDst1 = hiddenToHiddenOp.get_destination_cooperative_tensor<HiddenTensor, decltype(layer1Weights), half>();
    hiddenToHiddenOp.run(layer1Input, layer1Weights, hiddenDst1);
    applyBiasLeakyReLU(hiddenDst1, b1);

    constexpr auto hiddenToOutputDesc = matmul2d_descriptor(PIXEL_BATCH_SIZE, MLP_OUTPUT, NUM_HIDDEN, false, true, true);
    matmul2d<hiddenToOutputDesc, execution_simdgroup> hiddenToOutputOp;

    const bool layer2Compatible = hiddenToOutputOp.is_compatible_as_left_input<half, half, half>(hiddenDst1);
    auto layer2Input = layer2Compatible
        ? hiddenToOutputOp.get_left_input_cooperative_tensor<half, half, half>(hiddenDst1)
        : hiddenToOutputOp.get_left_input_cooperative_tensor<half, half, half>();
    HiddenTensor a1Mat;
    if (StoreScratch || !layer2Compatible) {
        a1Mat = tensor(smem_a1, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
        hiddenDst1.store(a1Mat);
        simdgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!layer2Compatible) {
        layer2Input.load(a1Mat);
        simdgroup_barrier(mem_flags::mem_none);
    }

    auto outputMatrix = tensor(scratch, extents<int, MLP_OUTPUT, PIXEL_BATCH_SIZE>());
    hiddenToOutputOp.run(layer2Input, layer2Weights, outputMatrix);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    return outputMatrix;
}

#pragma mark - Irradiance techniques

kernel void irradianceMCComputeShader(
    uint2 gid [[thread_position_in_grid]],
    texture2d<half> normalBuffer   [[texture(TextureIndexNormalBuffer)]],
    tensor<device half, dextents<int, 3>> irradianceOutput [[buffer(BufferIndexOutputTensor)]],
    texture2d<float> envMap         [[texture(TextureIndexEnvironment)]])
{
    if (gid.x >= normalBuffer.get_width() || gid.y >= normalBuffer.get_height())
        return;

    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::repeat);

    float3 n = float3(normalBuffer.read(gid).xyz);
    if (length_squared(n) < 0.01) {
        irradianceOutput[0, gid.x, gid.y] = half(0);
        irradianceOutput[1, gid.x, gid.y] = half(0);
        irradianceOutput[2, gid.x, gid.y] = half(0);
        return;
    }

    float3 worldNormal = normalize(n);
    float3 irr = evaluateMonteCarloGI(worldNormal, envMap, linearSampler);
    irradianceOutput[0, gid.x, gid.y] = half(irr.x);
    irradianceOutput[1, gid.x, gid.y] = half(irr.y);
    irradianceOutput[2, gid.x, gid.y] = half(irr.z);
}

kernel void textureToTensorKernel(
    uint2 gid [[thread_position_in_grid]],
    texture2d<half> inputTexture    [[texture(TextureIndexNormalBuffer)]],
    tensor<device half, dextents<int, 3>> outputTensor [[buffer(BufferIndexNormalTensor)]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height())
        return;
    half3 n = inputTexture.read(gid).xyz;
    outputTensor[0, gid.x, gid.y] = n.x;
    outputTensor[1, gid.x, gid.y] = n.y;
    outputTensor[2, gid.x, gid.y] = n.z;
}

kernel void irradianceMLPComputeShader(
    uint2 threadPos [[thread_position_in_grid]],
    uint  lane      [[thread_index_in_simdgroup]],
    uint  sgIdx     [[simdgroup_index_in_threadgroup]],
    texture2d<half> normalBuffer   [[texture(TextureIndexNormalBuffer)]],
    tensor<device half, dextents<int, 3>> irradianceOutput [[buffer(BufferIndexOutputTensor)]],
    tensor<device half, extents<int, NUM_INPUT, NUM_HIDDEN>>  layer0Weights [[buffer(BufferIndexMLPLayer0)]],
    tensor<device half, extents<int, NUM_HIDDEN, NUM_HIDDEN>> layer1Weights [[buffer(BufferIndexMLPLayer1)]],
    tensor<device half, extents<int, NUM_HIDDEN, MLP_OUTPUT>> layer2Weights [[buffer(BufferIndexMLPLayer2)]],
    const device half *bias0 [[buffer(BufferIndexMLPBias0)]],
    const device half *bias1 [[buffer(BufferIndexMLPBias1)]],
    const device half *bias2 [[buffer(BufferIndexMLPBias2)]])
{
    int W = normalBuffer.get_width();
    int H = normalBuffer.get_height();
    int px = (int)threadPos.x;
    int py = (int)threadPos.y;
    bool inBounds = px < W && py < H;

    bool hasSphere = inBounds && normalBuffer.read(uint2(px, py)).w > 0.5f;
    if (simd_all(!hasSphere)) return;

    threadgroup half scratch[THREADGROUP_SIZE * NUM_HIDDEN];
    threadgroup half *sgSmem = scratch + sgIdx * (PIXEL_BATCH_SIZE * NUM_HIDDEN);

    half3 normal = hasSphere ? normalBuffer.read(uint2(px, py)).xyz : half3(0);
    auto outputMatrix = mlpInference<false>(lane, normal,
        layer0Weights, layer1Weights, layer2Weights, bias0, bias1, bias2, sgSmem, sgSmem, sgSmem);

    if (hasSphere) {
        float3 logOut = float3(float(outputMatrix.get(0, lane) + bias2[0]),
                               float(outputMatrix.get(1, lane) + bias2[1]),
                               float(outputMatrix.get(2, lane) + bias2[2]));
        float3 irr = max(exp(logOut) - 1.0f, 0.0f);
        irradianceOutput[0, px, py] = half(irr.x);
        irradianceOutput[1, px, py] = half(irr.y);
        irradianceOutput[2, px, py] = half(irr.z);
    }
}

#pragma mark - Training kernels

static void atomicAddFloat(device atomic_uint *ptr, float val)
{
    uint old = atomic_load_explicit(ptr, memory_order_relaxed);
    uint desired;
    do {
        desired = as_type<uint>(as_type<float>(old) + val);
    } while (!atomic_compare_exchange_weak_explicit(
        ptr, &old, desired, memory_order_relaxed, memory_order_relaxed));
}

kernel void generateSamplesKernel(
    uint tid [[thread_position_in_grid]],
    texture2d<float> envMap   [[texture(0)]],
    device half *trainData    [[buffer(0)]],
    constant uint &batchSize  [[buffer(1)]])
{
    if (tid >= batchSize) return;

    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::repeat);

    float2 xi = hammersley(tid, batchSize);
    float cosTheta = 1.0f - 2.0f * xi.y;
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float phi = 2.0f * M_PI_F * xi.x;
    float3 normal = float3(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi));

    float3 irradiance = evaluateMonteCarloGI(normal, envMap, linearSampler, 512);
    float3 logIrr = log(1.0f + irradiance);

    trainData[tid * 6 + 0] = half(normal.x);
    trainData[tid * 6 + 1] = half(normal.y);
    trainData[tid * 6 + 2] = half(normal.z);
    trainData[tid * 6 + 3] = half(logIrr.x);
    trainData[tid * 6 + 4] = half(logIrr.y);
    trainData[tid * 6 + 5] = half(logIrr.z);
}

template<typename CoopTensor, typename ActCoop>
static void applyLeakyReLUDerivativeAndAccumBias(
    thread CoopTensor &coop, thread ActCoop &aCoop, thread float *biasPartials)
{
    simdgroup_barrier(mem_flags::mem_none);
    for (uint16_t i = 0; i < coop.get_capacity(); ++i) {
        int col = coop.get_multidimensional_index(i)[0];
        half d  = coop[i] * (aCoop[i] > 0.0h ? 1.0h : LEAKY_ALPHA_H);
        coop[i] = d;
        biasPartials[col] += float(d);
    }
}

kernel void mlpTrainStepKernel(
    uint2 threadPos [[thread_position_in_grid]],
    uint  lane      [[thread_index_in_simdgroup]],
    tensor<device half, extents<int, NUM_INPUT, NUM_HIDDEN>>  layer0Weights [[buffer(BufferIndexMLPLayer0)]],
    tensor<device half, extents<int, NUM_HIDDEN, NUM_HIDDEN>> layer1Weights [[buffer(BufferIndexMLPLayer1)]],
    tensor<device half, extents<int, NUM_HIDDEN, MLP_OUTPUT>> layer2Weights [[buffer(BufferIndexMLPLayer2)]],
    const device half *b0          [[buffer(BufferIndexMLPBias0)]],
    const device half *b1          [[buffer(BufferIndexMLPBias1)]],
    const device half *b2          [[buffer(BufferIndexMLPBias2)]],
    device atomic_uint *grad0      [[buffer(BufferIndexMLPGradLayer0)]],
    device atomic_uint *grad1      [[buffer(BufferIndexMLPGradLayer1)]],
    device atomic_uint *grad2      [[buffer(BufferIndexMLPGradLayer2)]],
    device atomic_uint *gradBias0  [[buffer(BufferIndexMLPGradBias0)]],
    device atomic_uint *gradBias1  [[buffer(BufferIndexMLPGradBias1)]],
    device atomic_uint *gradBias2  [[buffer(BufferIndexMLPGradBias2)]],
    device const half *trainData   [[buffer(BufferIndexMLPTrainData)]],
    constant TrainingLayerDims &dims [[buffer(BufferIndexMLPDims)]])
{
    uint tid = threadPos.x;
    bool valid = tid < dims.batchSize;

    threadgroup half scratch[PIXEL_BATCH_SIZE * NUM_INPUT];
    threadgroup half smem_a0[PIXEL_BATCH_SIZE * NUM_HIDDEN];
    threadgroup half smem_a1[PIXEL_BATCH_SIZE * NUM_HIDDEN];
    threadgroup half smem_dy[PIXEL_BATCH_SIZE * MLP_OUTPUT];
    threadgroup half smem_dz1[PIXEL_BATCH_SIZE * NUM_HIDDEN];
    threadgroup half smem_dz0[PIXEL_BATCH_SIZE * NUM_HIDDEN];

    // Forward pass.
    half3 normal = valid ? half3(trainData[tid*6+0], trainData[tid*6+1], trainData[tid*6+2]) : half3(0);
    auto outputMatrix = mlpInference<true>(lane, normal,
        layer0Weights, layer1Weights, layer2Weights, b0, b1, b2, scratch, smem_a0, smem_a1);

    // Loss gradient.
    const int N2      = dims.N2;
    const float scale = 2.0f / float(dims.batchSize);

    float x[3]      = {0.0f, 0.0f, 0.0f};
    float target[3] = {0.0f, 0.0f, 0.0f};
    float y[3]      = {0.0f, 0.0f, 0.0f};
    float dy[3]     = {0.0f, 0.0f, 0.0f};

    if (valid) {
        x[0]      = float(trainData[tid*6+0]);
        x[1]      = float(trainData[tid*6+1]);
        x[2]      = float(trainData[tid*6+2]);
        target[0] = float(trainData[tid*6+3]);
        target[1] = float(trainData[tid*6+4]);
        target[2] = float(trainData[tid*6+5]);
        for (int j = 0; j < N2; j++) {
            y[j]  = float(outputMatrix.get(j, (int)lane)) + float(b2[j]);
            dy[j] = scale * (y[j] - target[j]);
        }
    }

    // Phase 1: dW2 = dY^T * A1.
    auto dyMat = tensor(smem_dy, extents<int, MLP_OUTPUT, PIXEL_BATCH_SIZE>());
    for (int j = 0; j < MLP_OUTPUT; j++) {
        half v = (j < N2) ? half(dy[j]) : 0.0h;
        dyMat.set(v, j, lane);
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);

    auto a1Mat = tensor(smem_a1, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());

    constexpr auto dW2Desc = matmul2d_descriptor(MLP_OUTPUT, NUM_HIDDEN, PIXEL_BATCH_SIZE, true, false, true);
    matmul2d<dW2Desc, execution_simdgroup> dW2Op;

    auto dW2Coop = dW2Op.get_destination_cooperative_tensor<decltype(dyMat), decltype(a1Mat), half>();
    dW2Op.run(dyMat, a1Mat, dW2Coop);

    for (uint16_t i = 0; i < dW2Coop.get_capacity(); ++i) {
        auto idx = dW2Coop.get_multidimensional_index(i);
        int k = idx[0], j = idx[1];
        if (j < N2)
            atomicAddFloat(&grad2[j * NUM_HIDDEN + k], float(dW2Coop[i]));
    }

    // Phase 2: dA1 = dY * W2^T.
    // K=MLP_OUTPUT=8 is not a multiple of 16, so use dynamic_extent.
    constexpr auto dA1Desc = matmul2d_descriptor(PIXEL_BATCH_SIZE, NUM_HIDDEN, (int)metal::dynamic_extent, false, false, true);
    matmul2d<dA1Desc, execution_simdgroup> dA1Op;

    auto dA1Coop = dA1Op.get_destination_cooperative_tensor<decltype(dyMat), decltype(layer2Weights), half>();
    dA1Op.run(dyMat, layer2Weights, dA1Coop);

    // Phase 3a: LeakyReLU' -> dZ1, fused with bias1 partial.
    auto a1MatTensor = tensor(smem_a1, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
    auto a1Coop = dA1Op.get_destination_cooperative_tensor<decltype(dyMat), decltype(layer2Weights), half>();
    a1Coop.load(a1MatTensor);

    float bias1Partials[NUM_HIDDEN];
    for (int j = 0; j < NUM_HIDDEN; j++) bias1Partials[j] = 0.0f;
    applyLeakyReLUDerivativeAndAccumBias(dA1Coop, a1Coop, bias1Partials);

    auto dz1Mat = tensor(smem_dz1, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
    dA1Coop.store(dz1Mat);
    simdgroup_barrier(mem_flags::mem_threadgroup);

    // Phase 3b: dW1 = dZ1^T * A0.
    auto a0Mat = tensor(smem_a0, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());

    constexpr auto dW1Desc = matmul2d_descriptor(NUM_HIDDEN, NUM_HIDDEN, PIXEL_BATCH_SIZE, true, false, true);
    matmul2d<dW1Desc, execution_simdgroup> dW1Op;

    auto dW1Coop = dW1Op.get_destination_cooperative_tensor<decltype(dz1Mat), decltype(a0Mat), half>();
    dW1Op.run(dz1Mat, a0Mat, dW1Coop);

    for (uint16_t i = 0; i < dW1Coop.get_capacity(); ++i) {
        auto idx = dW1Coop.get_multidimensional_index(i);
        int k = idx[0], j = idx[1];
        atomicAddFloat(&grad1[j * NUM_HIDDEN + k], float(dW1Coop[i]));
    }

    // Phase 4: dA0 = dZ1 * W1^T.
    constexpr auto dA0Desc = matmul2d_descriptor(PIXEL_BATCH_SIZE, NUM_HIDDEN, NUM_HIDDEN, false, false, true);
    matmul2d<dA0Desc, execution_simdgroup> dA0Op;

    auto dA0Coop = dA0Op.get_destination_cooperative_tensor<decltype(dz1Mat), decltype(layer1Weights), half>();
    dA0Op.run(dz1Mat, layer1Weights, dA0Coop);

    // Phase 5a: LeakyReLU' -> dZ0, fused with bias0 partial.
    auto a0MatTensor = tensor(smem_a0, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
    auto a0Coop = dA0Op.get_destination_cooperative_tensor<decltype(dz1Mat), decltype(layer1Weights), half>();
    a0Coop.load(a0MatTensor);

    float bias0Partials[NUM_HIDDEN];
    for (int j = 0; j < NUM_HIDDEN; j++) bias0Partials[j] = 0.0f;
    applyLeakyReLUDerivativeAndAccumBias(dA0Coop, a0Coop, bias0Partials);

    auto dz0Mat = tensor(smem_dz0, extents<int, NUM_HIDDEN, PIXEL_BATCH_SIZE>());
    dA0Coop.store(dz0Mat);

    auto xMat = tensor(scratch, extents<int, NUM_INPUT, PIXEL_BATCH_SIZE>());
    for (int k = 0; k < 3; k++)
        xMat.set(half(x[k]), k, lane);
    for (int k = 3; k < NUM_INPUT; k++)
        xMat.set(0.0h, k, lane);
    simdgroup_barrier(mem_flags::mem_threadgroup);

    // Phase 5b: dW0 = dZ0^T * X.
    constexpr auto dW0Desc = matmul2d_descriptor(NUM_HIDDEN, NUM_INPUT, PIXEL_BATCH_SIZE, true, false, true);
    matmul2d<dW0Desc, execution_simdgroup> dW0Op;

    auto dW0Coop = dW0Op.get_destination_cooperative_tensor<decltype(dz0Mat), decltype(xMat), half>();
    dW0Op.run(dz0Mat, xMat, dW0Coop);

    for (uint16_t i = 0; i < dW0Coop.get_capacity(); ++i) {
        auto idx = dW0Coop.get_multidimensional_index(i);
        int k = idx[0], j = idx[1];
        if (k < 3)
            atomicAddFloat(&grad0[j * NUM_INPUT + k], float(dW0Coop[i]));
    }

    // Phase 6: bias gradients.
    for (int j = 0; j < N2; j++) {
        float gb2 = simd_sum(dy[j]);
        if (lane == 0) atomicAddFloat(&gradBias2[j], gb2);
    }
    for (int j = 0; j < NUM_HIDDEN; j++) {
        float gb1 = simd_sum(bias1Partials[j]);
        if (lane == 0) atomicAddFloat(&gradBias1[j], gb1);
    }
    for (int j = 0; j < NUM_HIDDEN; j++) {
        float gb0 = simd_sum(bias0Partials[j]);
        if (lane == 0) atomicAddFloat(&gradBias0[j], gb0);
    }
}

#pragma mark - Adam optimizer

static float adamUpdate(uint tid, device const atomic_uint *gradBuf,
                         device float *masterW, device float *adamM, device float *adamV,
                         constant AdamUpdateParams &p)
{
    float g = as_type<float>(atomic_load_explicit(&gradBuf[tid], memory_order_relaxed));

    float m = p.beta1 * adamM[tid] + (1.0f - p.beta1) * g;
    float v = p.beta2 * adamV[tid] + (1.0f - p.beta2) * g * g;
    adamM[tid] = m;
    adamV[tid] = v;

    float mHat = m / (1.0f - pow(p.beta1, float(p.adamStep)));
    float vHat = v / (1.0f - pow(p.beta2, float(p.adamStep)));

    float w = masterW[tid] - p.lr * mHat / (sqrt(vHat) + p.eps);
    masterW[tid] = w;
    return w;
}

kernel void adamUpdateWeightsKernel(
    uint2 tid [[thread_position_in_grid]],
    device const atomic_uint *gradBuf                      [[buffer(0)]],
    device float *masterW                                  [[buffer(1)]],
    device float *adamM                                    [[buffer(2)]],
    device float *adamV                                    [[buffer(3)]],
    tensor<device half, dextents<int, 2>> inferenceW       [[buffer(4)]],
    constant AdamUpdateParams &p                           [[buffer(5)]])
{
    uint flatIdx = tid.x + tid.y * p.cols;
    if (tid.x >= p.cols || tid.y >= p.rows) return;
    float w = adamUpdate(flatIdx, gradBuf, masterW, adamM, adamV, p);
    inferenceW[tid.x, tid.y] = half(w);
}

kernel void adamUpdateBiasKernel(
    uint tid [[thread_position_in_grid]],
    device const atomic_uint *gradBuf [[buffer(0)]],
    device float *masterW             [[buffer(1)]],
    device float *adamM               [[buffer(2)]],
    device float *adamV               [[buffer(3)]],
    device half *inferenceW           [[buffer(4)]],
    constant AdamUpdateParams &p      [[buffer(5)]])
{
    if (tid >= p.rows) return;
    float w = adamUpdate(tid, gradBuf, masterW, adamM, adamV, p);
    inferenceW[tid] = half(w);
}

#pragma mark - Kaiming initialization

static uint wangHash(uint seed)
{
    seed = (seed ^ 61) ^ (seed >> 16);
    seed *= 9;
    seed = seed ^ (seed >> 4);
    seed *= 0x27d4eb2d;
    seed = seed ^ (seed >> 15);
    return seed;
}

kernel void kaimingInitKernel(
    uint2 tid [[thread_position_in_grid]],
    device float *masterW                             [[buffer(0)]],
    tensor<device half, dextents<int, 2>> inferenceW  [[buffer(1)]],
    constant KaimingInitParams &p                     [[buffer(2)]])
{
    if (tid.x >= p.cols || tid.y >= p.rows) return;

    uint flatIdx = tid.x + tid.y * p.cols;
    float r = float(wangHash(flatIdx ^ p.seed)) / float(0xFFFFFFFF) * 2.0f - 1.0f;
    float w = r / sqrt(float(p.fanIn));
    masterW[flatIdx] = w;
    inferenceW[tid.x, tid.y] = half(w);
}
