/*
 * Filename: backend_metal_raytracing.mm
 * Project: Appine (App in Emacs)
 * Description: A Metal view in an appine tab, path tracing the instanced
 *              Cornell box from Apple's "Accelerating ray tracing using Metal"
 *              sample (src/backends/metal/raytracing/, see the README there).
 *
 * Objective-C++ because the sample's headers are (ShaderTypes.h, Scene.h).
 * The factory is exported with C linkage for appine_core.m.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "appine_backend.h"
#import "metal/raytracing/Renderer.h"
#import "metal/raytracing/AppineRayTracingShaders.h"

@interface AppineMetalRayTracingBackend : NSObject <AppineBackend>
@property(nonatomic, strong) NSView *view;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) MTKView *metalView;
@property(nonatomic, strong) AppineRTRenderer *renderer;
@end

@implementation AppineMetalRayTracingBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

// The sample's view controller: of the GPUs that support ray tracing, prefer
// one that is not low power (a discrete GPU on a dual-GPU Mac).
static id<MTLDevice> appine_raytracing_device(void) {
    id<MTLDevice> selected = nil;
    for (id<MTLDevice> device in MTLCopyAllDevices()) {
        if (device.supportsRaytracing && (!selected || !device.isLowPower)) {
            selected = device;
        }
    }
    return selected;
}

- (instancetype)init {
    if (self = [super init]) {
        _title = @"Metal Ray Tracing";

        id<MTLDevice> device = appine_raytracing_device();
        if (!device) {
            _view = appine_metal_message_view(@"Metal ray tracing is not supported on this Mac.");
            return self;
        }
        // Built like the sample's Metal 3 targets (SUPPORTS_METAL_3=1).
        if (![device supportsFamily:MTLGPUFamilyMetal3]) {
            _view = appine_metal_message_view(
                [NSString stringWithFormat:@"%@ does not support Metal 3, which this ray tracer is built for.", device.name]);
            return self;
        }
        // Compile the shaders before the renderer asks for them, so a failure
        // shows a message here instead of a renderer with no pipelines.
        if (!appine_raytracing_shader_library(device)) {
            _view = appine_metal_message_view(@"The ray tracing shaders failed to compile; see the Emacs log (NSLog).");
            return self;
        }

        _metalView = [[MTKView alloc] initWithFrame:NSZeroRect device:device];
        _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // As in the sample's view controller.
        _metalView.colorPixelFormat = MTLPixelFormatRGBA16Float;

        AppineRTScene *scene = [AppineRTScene newInstancedCornellBoxSceneWithDevice:device
                                                           useIntersectionFunctions:YES];
        _renderer = [[AppineRTRenderer alloc] initWithDevice:device scene:scene];
        // MTKView keeps its delegate weak; the backend holds the strong
        // reference. The renderer sizes its targets on the first nonzero
        // drawableSizeWillChange, once Emacs has placed the view.
        _metalView.delegate = _renderer;
        _view = _metalView;
    }
    return self;
}

- (void)cleanup {
    self.metalView.paused = YES;
    self.metalView.delegate = nil;
    self.renderer = nil;
}

@end

// C API export
extern "C" id<AppineBackend> appine_create_metal_raytracing_backend(void) {
    return [[AppineMetalRayTracingBackend alloc] init];
}
