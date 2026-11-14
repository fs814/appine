/*
 * Filename: AppineShadertoyTranslator.h
 * Project: Appine (App in Emacs)
 * Description: Shadertoy GLSL -> Metal Shading Language, through shaderc
 *              (GLSL -> SPIR-V) and SPIRV-Cross (SPIR-V -> MSL) from the
 *              Vulkan SDK. See README.md in this directory.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Size and layout of the uniform block every translated pass receives at
/// buffer index 4 (std140; see the GLSL prelude in the .m file).
typedef struct {
    float iResolution[3]; float iTime;
    float iTimeDelta; float iFrameRate; int32_t iFrame; float iSampleRate;
    float iMouse[4];
    float iDate[4];
    float iChannelTime[4][4];        // [n][0] is iChannelTime[n]
    float iChannelResolution[4][4];  // [n][0..2] is iChannelResolution[n]
} AppineShadertoyUniforms;

/// Buffer index of the uniform block; iChannelN is texture N and sampler N.
enum { AppineShadertoyUniformBufferIndex = 4 };

/// YES when appine was built with the Vulkan SDK (shaderc + SPIRV-Cross).
BOOL appine_shadertoy_translator_available(void);

/// Translates one Shadertoy pass to MSL. The fragment function is `main0`.
/// COMMON is the shader's Common tab (may be empty). CHANNEL_TYPES has four
/// GLSL sampler types ("sampler2D", "samplerCube" or "sampler3D").
/// Returns nil and sets ERROR (GLSL compiler messages, with line numbers
/// relative to CODE) on failure.
NSString *_Nullable appine_shadertoy_translate(NSString *common, NSString *code,
                                               NSArray<NSString *> *channelTypes,
                                               NSString *passName,
                                               NSString *_Nullable *_Nonnull error);

NS_ASSUME_NONNULL_END
