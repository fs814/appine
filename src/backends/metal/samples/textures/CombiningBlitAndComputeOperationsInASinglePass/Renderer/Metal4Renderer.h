/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A platform-independent Metal renderer interface that sets up the app's
 resources once and then draws each frame.
*/

@import MetalKit;

/// A renderer for systems that support Metal 4 GPUs.
@interface Metal4Renderer : NSObject<MTKViewDelegate>

- (nonnull instancetype)initWithView:(nonnull MTKView *)mtkView;

@end
