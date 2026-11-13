/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A protocol interface for renderer types.
*/

#import <MetalKit/MetalKit.h>

// appine: APPINE_METAL_ASSERT and the runtime shader compiler, shared with the
// ray tracing sample.
#import "../common/AppineMetalCommon.h"

/// appine: this sample's shaders, compiled at runtime (AppineTriangleShaders.m)
/// because a dylib has no app bundle for `newDefaultLibrary` to read.
/// Returns nil (and logs why) when the source does not compile.
id<MTLLibrary> _Nullable appine_triangle_shader_library(id<MTLDevice> _Nonnull device);

/// A minimal interface for a renderer type.
@protocol Renderer <NSObject>

- (nonnull instancetype) initWithMetalKitView:(nonnull MTKView *) view;

/// Informs the renderer when the size of the view changes.
/// - Parameter size: The new viewport size.
- (void) updateViewportSize:(CGSize) size;

/// Instructs the renderer to draw a frame for a view.
/// - Parameter view: A view the renderer draws to, which provides:
///     - A render pass descriptor that reflects the view's current configuration
///     - A drawable instance that the render draws to
- (void) renderFrameToView:(nonnull MTKView *) view;

@end

