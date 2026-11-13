/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the Metal 4 renderer.
*/

#if __has_include(<Metal/MTL4CommandQueue.h>) // appine: Metal 4 needs the macOS 26+ SDK

#import "RendererProtocol.h"

/// A renderer for systems that support Metal 4 GPUs.
API_AVAILABLE(ios(26.0), tvos(26.0), macos(26.0))
@interface Metal4Renderer : NSObject<Renderer>

/// The Metal device the renderer draws with by sending commands to it.
///
/// The device instance also creates various resources the renderer needs to
/// encode and submit its commands.
@property (nonatomic, readonly) id<MTLDevice> device;

/// The app's default Metal library.
///
/// The default library stores all of the project's shaders that Xcode
/// compiles at build time.
@property (nonatomic, readonly) id<MTLLibrary> defaultLibrary;

@end

#endif
