/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the Metal 4 renderer's methods that set up the render's resources.
*/

#if __has_include(<Metal/MTL4CommandQueue.h>) // appine: Metal 4 needs the macOS 26+ SDK

#import "Metal4Renderer.h"

@interface Metal4Renderer (Setup)

- (nonnull NSArray<id<MTLBuffer>> *) makeTriangleDataBuffers:(NSUInteger) count;

- (nonnull id<MTL4ArgumentTable>) makeArgumentTable;

- (nonnull id<MTLResidencySet>) makeResidencySet;

- (nonnull NSArray<id<MTL4CommandAllocator>> *) makeCommandAllocators:(NSUInteger) count;

@end

#endif
