/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Shared type definitions used by both the host application and the Metal shaders.
*/

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#ifdef __METAL_VERSION__
using namespace metal;

static float2 directionToEquirectangular(float3 dir)
{
    float phi = atan2(dir.z, dir.x);
    float theta = asin(clamp(dir.y, -1.0f, 1.0f));
    return float2(phi / (2.0 * M_PI_F) + 0.5, -theta / M_PI_F + 0.5);
}
#endif

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshNormals   = 1,
    BufferIndexMeshTexcoords = 2,
    BufferIndexUniforms      = 3,
    BufferIndexNormalTensor  = 4,
    BufferIndexOutputTensor  = 5,
    BufferIndexMLPLayer0     = 6,
    BufferIndexMLPLayer1     = 7,
    BufferIndexMLPLayer2     = 8,
    BufferIndexMLPBias0      = 9,
    BufferIndexMLPBias1      = 10,
    BufferIndexMLPBias2      = 11,
    BufferIndexMLPGradLayer0     = 12,
    BufferIndexMLPGradLayer1     = 13,
    BufferIndexMLPGradLayer2     = 14,
    BufferIndexMLPGradBias0      = 15,
    BufferIndexMLPGradBias1      = 16,
    BufferIndexMLPGradBias2      = 17,
    BufferIndexMLPTrainData      = 18,
    BufferIndexMLPDims           = 19,
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition = 0,
    VertexAttributeNormal   = 1,
    VertexAttributeTexcoord = 2,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexEnvironment      = 0,
    TextureIndexNormalMap         = 1,
    TextureIndexNormalBuffer      = 2,
    TextureIndexARMMap            = 3,
    TextureIndexARMBuffer         = 4,
};

typedef struct
{
    matrix_float4x4 inverseViewProjection;
    matrix_float4x4 modelViewProjection;
    float exposure;
} Uniforms;

#define MLP_NUM_LAYERS 3

#define TRAINING_BATCH_SIZE 512

typedef struct {
    uint32_t N2;
    uint32_t batchSize;
} TrainingLayerDims;

typedef struct {
    uint32_t rows, cols;
    uint32_t adamStep;
    float beta1, beta2, eps, lr;
} AdamUpdateParams;

typedef struct {
    uint32_t cols;
    uint32_t rows;
    uint32_t fanIn;
    uint32_t seed;
} KaimingInitParams;

#endif /* ShaderTypes_h */
