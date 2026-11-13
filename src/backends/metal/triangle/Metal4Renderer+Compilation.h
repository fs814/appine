/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the Metal 4 renderer's method that compiles a render pipeline.
*/

#if __has_include(<Metal/MTL4CommandQueue.h>) // appine: Metal 4 needs the macOS 26+ SDK

#import "Metal4Renderer.h"

@interface Metal4Renderer (Compilation)

- (id<MTLRenderPipelineState>) compileRenderPipeline:(MTLPixelFormat) colorPixelFormat;

@end

#endif
