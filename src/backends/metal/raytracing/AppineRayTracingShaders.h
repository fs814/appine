/*
 * Filename: AppineRayTracingShaders.h
 * Project: Appine (App in Emacs)
 * Description: The ray tracing sample's shader library, compiled at runtime
 *              (AppineRayTracingShaders.m) because a dylib has no app bundle
 *              for -[MTLDevice newDefaultLibrary] to read.
 */
#ifndef APPINE_RAYTRACING_SHADERS_H
#define APPINE_RAYTRACING_SHADERS_H

#import "../common/AppineMetalCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Compiled with SUPPORTS_METAL_3=1 and Metal language 3.0, as the sample's
/// Xcode project does. Returns nil (and logs why) when compilation fails.
id<MTLLibrary> _Nullable appine_raytracing_shader_library(id<MTLDevice> _Nonnull device);

#ifdef __cplusplus
}
#endif

#endif /* APPINE_RAYTRACING_SHADERS_H */
