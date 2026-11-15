/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Geometry pass shaders that rasterize world-space normals and material parameters into G-buffer textures for use by the irradiance and composite passes.
*/

#include <metal_stdlib>
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float3 normal   [[attribute(VertexAttributeNormal)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} SphereVertex;

typedef struct
{
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
} SphereVertexOut;

vertex SphereVertexOut geometryVertexShader(SphereVertex in [[stage_in]],
                                            constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]])
{
    SphereVertexOut out;
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
    out.worldPosition = in.position;
    out.worldNormal = in.normal;
    out.texCoord = in.texCoord;
    return out;
}

typedef struct
{
    float4 normal [[color(0)]];
    float4 arm    [[color(1)]];
} GeometryFragmentOut;

fragment GeometryFragmentOut geometryFragmentShader(SphereVertexOut in [[stage_in]],
                                       texture2d<float> normalMap [[texture(TextureIndexNormalMap)]],
                                       texture2d<float> armMap [[texture(TextureIndexARMMap)]])
{
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::repeat);

    float3 dPdx = dfdx(in.worldPosition);
    float3 dPdy = dfdy(in.worldPosition);
    float2 dUVdx = dfdx(in.texCoord);
    float2 dUVdy = dfdy(in.texCoord);

    float3 T = normalize(dPdx * dUVdy.y - dPdy * dUVdx.y);
    float3 B = normalize(dPdy * dUVdx.x - dPdx * dUVdy.x);
    float3 N = normalize(in.worldNormal);
    float3x3 TBN = float3x3(T, B, N);

    float3 normalTS = normalMap.sample(texSampler, in.texCoord).rgb * 2.0 - 1.0;
    float3 worldNormal = normalize(TBN * normalTS);

    float4 armSample = armMap.sample(texSampler, in.texCoord);

    GeometryFragmentOut out;
    out.normal = float4(worldNormal, 1.0);
    out.arm = armSample;
    return out;
}
