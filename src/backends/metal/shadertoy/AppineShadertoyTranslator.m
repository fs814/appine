/*
 * Filename: AppineShadertoyTranslator.m
 * Project: Appine (App in Emacs)
 * Description: Shadertoy GLSL -> MSL. See AppineShadertoyTranslator.h.
 */
#import "AppineShadertoyTranslator.h"

#if APPINE_HAVE_SHADERC
#include <shaderc/shaderc.h>
#include <spirv_cross/spirv_cross_c.h>

BOOL appine_shadertoy_translator_available(void) { return YES; }

// What Shadertoy puts in front of every pass, as Vulkan-flavoured GLSL ES.
// The block is std140 and matches AppineShadertoyUniforms byte for byte.
// %@ x4: the sampler types of iChannel0..3.
static NSString *const kPrelude =
    @"#version 310 es\n"
    "precision highp float;\nprecision highp int;\n"
    "precision highp sampler2D;\nprecision highp samplerCube;\nprecision highp sampler3D;\n"
    "layout(std140, set = 0, binding = 4) uniform AppineShadertoyUniforms {\n"
    "    vec3 iResolution; float iTime;\n"
    "    float iTimeDelta; float iFrameRate; int iFrame; float iSampleRate;\n"
    "    vec4 iMouse;\n"
    "    vec4 iDate;\n"
    "    float iChannelTime[4];\n"
    "    vec3 iChannelResolution[4];\n"
    "};\n"
    "layout(set = 0, binding = 0) uniform %@ iChannel0;\n"
    "layout(set = 0, binding = 1) uniform %@ iChannel1;\n"
    "layout(set = 0, binding = 2) uniform %@ iChannel2;\n"
    "layout(set = 0, binding = 3) uniform %@ iChannel3;\n"
    "layout(location = 0) out vec4 appine_fragColor;\n"
    "#define HW_PERFORMANCE 1\n";

// gl_FragCoord is used as is. Metal's origin is top-left and Shadertoy's is
// bottom-left, so every pass renders upside down in memory, consistently
// (buffers read back what they wrote); the renderer flips once, on screen.
static NSString *const kMain =
    @"\nvoid main() {\n"
    "    vec4 appine_color = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    mainImage(appine_color, gl_FragCoord.xy);\n"
    "    appine_fragColor = appine_color;\n"
    "}\n";

NSString *appine_shadertoy_translate(NSString *common, NSString *code,
                                     NSArray<NSString *> *types, NSString *passName,
                                     NSString **error) {
    NSString *glsl = [NSString stringWithFormat:@"%@#line 1\n%@\n#line 1\n%@%@",
                      [NSString stringWithFormat:kPrelude, types[0], types[1], types[2], types[3]],
                      common ?: @"", code, kMain];
    NSData *source = [glsl dataUsingEncoding:NSUTF8StringEncoding];
    NSString *msl = nil;

    shaderc_compiler_t compiler = shaderc_compiler_initialize();
    shaderc_compile_options_t options = shaderc_compile_options_initialize();
    shaderc_compile_options_set_target_env(options, shaderc_target_env_vulkan, shaderc_env_version_vulkan_1_1);
    shaderc_compilation_result_t result =
        shaderc_compile_into_spv(compiler, source.bytes, source.length, shaderc_glsl_fragment_shader,
                                 passName.UTF8String, "main", options);

    if (shaderc_result_get_compilation_status(result) != shaderc_compilation_status_success) {
        *error = [NSString stringWithFormat:@"%@: GLSL did not compile:\n%s", passName,
                  shaderc_result_get_error_message(result)];
    } else {
        spvc_context context = NULL;
        spvc_parsed_ir ir = NULL;
        spvc_compiler cross = NULL;
        spvc_compiler_options crossOptions = NULL;
        const char *output = NULL;
        spvc_context_create(&context);
        if (spvc_context_parse_spirv(context, (const SpvId *)shaderc_result_get_bytes(result),
                                     shaderc_result_get_length(result) / sizeof(SpvId), &ir) == SPVC_SUCCESS &&
            spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &cross) == SPVC_SUCCESS &&
            spvc_compiler_create_compiler_options(cross, &crossOptions) == SPVC_SUCCESS &&
            spvc_compiler_options_set_uint(crossOptions, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(2, 3, 0)) == SPVC_SUCCESS &&
            // GLSL binding N becomes buffer/texture/sampler index N.
            spvc_compiler_options_set_bool(crossOptions, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, SPVC_TRUE) == SPVC_SUCCESS &&
            spvc_compiler_install_compiler_options(cross, crossOptions) == SPVC_SUCCESS &&
            spvc_compiler_compile(cross, &output) == SPVC_SUCCESS) {
            msl = [NSString stringWithUTF8String:output];
        } else {
            *error = [NSString stringWithFormat:@"%@: SPIR-V to Metal failed: %s", passName,
                      spvc_context_get_last_error_string(context)];
        }
        spvc_context_destroy(context);
    }

    shaderc_result_release(result);
    shaderc_compile_options_release(options);
    shaderc_compiler_release(compiler);
    return msl;
}

#else  // built without the Vulkan SDK

BOOL appine_shadertoy_translator_available(void) { return NO; }

NSString *appine_shadertoy_translate(NSString *common, NSString *code,
                                     NSArray<NSString *> *types, NSString *passName,
                                     NSString **error) {
    *error = @"appine was built without the Vulkan SDK, so it cannot translate GLSL.";
    return nil;
}

#endif
