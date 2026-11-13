/*
 * Filename: backend_metal_triangle.m
 * Project: Appine (App in Emacs)
 * Description: A Metal view in an appine tab, drawing the colorful rotating
 *              triangle from Apple's "Drawing a triangle with Metal 4" sample
 *              (src/backends/metal/triangle/, see the README there).
 *
 * The backend owns an MTKView and the sample's MetalKitViewDelegate, which picks
 * the Metal 4 renderer when the GPU supports MTLGPUFamilyMetal4 (Apple silicon
 * on macOS 26+) and the classic Metal renderer otherwise.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "appine_backend.h"
#import "metal/triangle/MetalKitViewDelegate.h"
#import "metal/triangle/RendererProtocol.h"

@interface AppineMetalTriangleBackend : NSObject <AppineBackend>
@property(nonatomic, strong) NSView *view;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) MTKView *metalView;
@property(nonatomic, strong) MetalKitViewDelegate *renderDelegate;
@end

@implementation AppineMetalTriangleBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

- (instancetype)init {
    if (self = [super init]) {
        _title = @"Metal Triangle";

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            _view = appine_metal_message_view(@"Metal is not supported on this Mac.");
            return self;
        }
        // Compile the shaders before the renderers ask for them, so a failure
        // shows a message here instead of a renderer with no pipeline.
        if (!appine_triangle_shader_library(device)) {
            _view = appine_metal_message_view(@"The triangle shaders failed to compile; see the Emacs log (NSLog).");
            return self;
        }

        _metalView = [[MTKView alloc] initWithFrame:NSZeroRect device:device];
        _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // The sample's pipeline descriptor (Descriptors.mtl4-json) uses BGRA8Unorm.
        _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _metalView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        // MTKView keeps its delegate weak; the backend holds the strong reference.
        _renderDelegate = [[MetalKitViewDelegate alloc] initWithMetalKitView:_metalView];
        _metalView.delegate = _renderDelegate;
        _view = _metalView;
    }
    return self;
}

- (void)cleanup {
    self.metalView.paused = YES;
    self.metalView.delegate = nil;
    self.renderDelegate = nil;
}

@end

// C API export
id<AppineBackend> appine_create_metal_triangle_backend(void) {
    return [[AppineMetalTriangleBackend alloc] init];
}
