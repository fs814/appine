/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Composite pass shaders that combine direct lighting from a Cook-Torrance BRDF with indirect lighting sampled from the irradiance tensor, then tone-map the result.
*/

#include <metal_stdlib>
#include <metal_tensor>
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float4 position [[position]];
    float2 uv;
    float2 clipCoord;
} FullscreenVertexOut;

vertex FullscreenVertexOut fullscreenVertexShader(uint vertexID [[vertex_id]])
{
    FullscreenVertexOut out;
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.clipCoord = out.position.xy;
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

struct MaterialParams
{
    float3 albedo;
    float  metallic;
    float  roughness;
    float  alpha;
    float3 F0;
    float3 diffuseColor;
};

static MaterialParams makeMaterial(float3 albedo, float metallic, float roughness)
{
    MaterialParams p;
    p.albedo       = albedo;
    p.metallic     = metallic;
    p.roughness    = max(roughness, 0.001f);
    p.alpha        = p.roughness * p.roughness;
    p.F0           = mix(float3(0.04f), albedo, metallic);
    p.diffuseColor = albedo * (1.0f - metallic);
    return p;
}

static float GGX_D(float NdotH, float alpha)
{
    float a2 = alpha * alpha;
    float d  = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    return a2 / (M_PI_F * d * d);
}

// Height-correlated Smith G2 visibility - folds 1/(4*NdotL*NdotV) into G,
// so specular = D * Vis * F with no separate denominator.
static float Smith_GGX_Vis(float NdotL, float NdotV, float alpha)
{
    float a2    = alpha * alpha;
    float ggxL  = NdotV * sqrt(NdotL * NdotL * (1.0f - a2) + a2);
    float ggxV  = NdotL * sqrt(NdotV * NdotV * (1.0f - a2) + a2);
    float denom = ggxL + ggxV;
    return (denom > 0.0f) ? 0.5f / denom : 0.0f;
}

static float3 F_Schlick(float3 F0, float VdotH)
{
    float u  = 1.0f - VdotH;
    float u2 = u * u;
    float u5 = u2 * u2 * u;
    return F0 + (1.0f - F0) * u5;
}

// Cook-Torrance GGX specular + energy-conserving Lambert diffuse.
static float3 evaluateBRDF(float3 N, float3 V, float3 L, MaterialParams p)
{
    float NdotL = dot(N, L);
    float NdotV = dot(N, V);
    if (NdotL <= 0.0f || NdotV <= 0.0f) return float3(0.0f);

    float3 H    = normalize(L + V);
    float NdotH = max(dot(N, H), 0.0f);
    float VdotH = max(dot(V, H), 0.0f);

    float  D = GGX_D(NdotH, p.alpha);
    float  G = Smith_GGX_Vis(NdotL, NdotV, p.alpha);
    float3 F = F_Schlick(p.F0, VdotH);

    float3 specular = D * G * F;
    float3 diffuse  = p.diffuseColor * (1.0f / M_PI_F) * (1.0f - F);
    return diffuse + specular;
}

// The standard ACES tonemap function from "Modern Rendering" sample.
static float3 ToneMapACES(float3 x)
{
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x*(a*x+b))/(x*(c*x+d)+e));
}

fragment float4 compositeFragmentShader(FullscreenVertexOut in [[stage_in]],
                                         constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                         texture2d<float> normalBuffer [[texture(TextureIndexNormalBuffer)]],
                                         texture2d<float> armBuffer [[texture(TextureIndexARMBuffer)]],
                                         texture2d<float> envMap [[texture(TextureIndexEnvironment)]],
                                         tensor<device half, dextents<int, 3>> irradianceTensor [[buffer(BufferIndexOutputTensor)]])
{
    constexpr sampler pointSampler(mag_filter::nearest, min_filter::nearest);
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::repeat);

    float4 normalSample = normalBuffer.sample(pointSampler, in.uv);

    float3 color;
    if (normalSample.w > 0.5) {
        float4 armSample = armBuffer.sample(pointSampler, in.uv);
        float ao        = armSample.r;
        float roughness = armSample.g;
        float metallic  = armSample.b;

        uint2 pos = uint2(in.position.xy);
        float3 irradiance = float3(float(irradianceTensor[0, pos.x, pos.y]),
                                   float(irradianceTensor[1, pos.x, pos.y]),
                                   float(irradianceTensor[2, pos.x, pos.y]));
        irradiance = max(irradiance, float3(0.0));

        float4 nearH = uniforms.inverseViewProjection * float4(in.clipCoord, 0.0, 1.0);
        float4 farH  = uniforms.inverseViewProjection * float4(in.clipCoord, 1.0, 1.0);
        float3 rayDir = normalize(farH.xyz / farH.w - nearH.xyz / nearH.w);
        float3 V = -rayDir;
        float3 N = normalize(normalSample.xyz);

        MaterialParams material = makeMaterial(float3(0.7f), metallic, roughness);

        const float3 sunL        = normalize(float3(0.622f, 0.642f, 0.448f));
        const float3 sunRadiance = float3(1.0f);

        float  NdotL_sun = max(dot(N, sunL), 0.0f);
        float3 direct = evaluateBRDF(N, V, sunL, material) * NdotL_sun * sunRadiance;

        float3 indirect = material.diffuseColor * (1.0f / M_PI_F) * irradiance * ao;

        color = direct + indirect;
    } else {
        float4 worldPos = uniforms.inverseViewProjection * float4(in.clipCoord, 1.0, 1.0);
        float3 dir = normalize(worldPos.xyz / worldPos.w);
        float2 envUV = directionToEquirectangular(dir);
        color = min(envMap.sample(linearSampler, envUV).rgb, float3(10.0f));
    }

    return float4(ToneMapACES(color * uniforms.exposure), 1.0);
}
