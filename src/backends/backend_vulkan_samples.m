/*
 * Filename: backend_vulkan_samples.m
 * Project: Appine (App in Emacs)
 * Description: A Khronos Vulkan-Samples sample in an appine tab
 *              (src/backends/vulkan/, see the README there).
 *
 * The samples and their framework are a separate, optional library,
 * appine-vulkan-samples.dylib, built by `make vulkan-samples` and loaded here
 * on first use. It draws through MoltenVK into this backend's CAMetalLayer.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#import "appine_backend.h"
#import "metal/common/AppineMetalCommon.h"
#import "vulkan/appine/appine_vulkan_samples.h"

// MARK: - The optional library

static struct {
    int (*start)(void *, const char *, const char *, uint32_t, uint32_t, float, char *, size_t);
    int (*frame)(char *, size_t);
    void (*resize)(uint32_t, uint32_t);
    void (*mouse)(int, float, float);
    void (*stop)(void);
    int (*running)(void);
} vks;

// The appine checkout: the folder of the module this code is in.
static NSString *appine_root_dir(void) {
    Dl_info info;
    if (!dladdr((const void *)&appine_root_dir, &info) || !info.dli_fname) return nil;
    return [[@(info.dli_fname) stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent];
}

// nil when loaded; otherwise what the tab should say.
static NSString *appine_vks_load(void) {
    static NSString *problem = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [appine_root_dir() stringByAppendingPathComponent:@"appine-vulkan-samples.dylib"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            problem = [NSString stringWithFormat:
                @"The Vulkan samples are not built yet.\n\nIn %@ run:\n"
                "  src/backends/vulkan/fetch_deps.sh\n  make vulkan-samples EMACS_INCLUDE_DIR=...",
                appine_root_dir()];
            return;
        }
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            problem = [NSString stringWithFormat:@"Cannot load appine-vulkan-samples.dylib:\n%s", dlerror()];
            return;
        }
        vks.start = dlsym(handle, "appine_vks_start");
        vks.frame = dlsym(handle, "appine_vks_frame");
        vks.resize = dlsym(handle, "appine_vks_resize");
        vks.mouse = dlsym(handle, "appine_vks_mouse");
        vks.stop = dlsym(handle, "appine_vks_stop");
        vks.running = dlsym(handle, "appine_vks_running");
        if (!vks.start || !vks.frame || !vks.resize || !vks.mouse || !vks.stop || !vks.running) {
            problem = @"appine-vulkan-samples.dylib is out of date; run `make vulkan-samples` again.";
        }
    });
    return problem;
}

// MARK: - View

@class AppineVulkanSamplesBackend;

// A view backed by the CAMetalLayer MoltenVK presents into.
@interface AppineVulkanView : NSView
@property (nonatomic, weak) AppineVulkanSamplesBackend *owner;
@end

// MARK: - Backend

@interface AppineVulkanSamplesBackend : NSObject <AppineBackend>
@property (nonatomic, strong) NSView *view;  // container: a message, or the Vulkan view
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *sampleId;
@property (nonatomic, strong) AppineVulkanView *vulkanView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL started;   // this backend owns the running sample
@property (nonatomic) CGSize pixelSize;
- (void)layoutChanged;
- (void)mouse:(int)action event:(NSEvent *)event;
@end

@implementation AppineVulkanView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    return self;
}
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self.owner layoutChanged]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.owner layoutChanged]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self.owner layoutChanged]; }
- (void)mouseDown:(NSEvent *)event { [self.owner mouse:0 event:event]; }
- (void)mouseUp:(NSEvent *)event { [self.owner mouse:1 event:event]; }
- (void)mouseDragged:(NSEvent *)event { [self.owner mouse:2 event:event]; }
@end

@implementation AppineVulkanSamplesBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

- (void)show:(NSView *)content {
    for (NSView *old in [self.view.subviews copy]) [old removeFromSuperview];
    content.frame = self.view.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:content];
}

- (void)fail:(NSString *)message {
    NSLog(@"[appine-vulkan] %@: %@", self.sampleId, message);
    [self.timer invalidate];
    self.timer = nil;
    if (self.started) { vks.stop(); self.started = NO; }
    [self show:appine_metal_message_view([NSString stringWithFormat:@"Vulkan sample %@\n\n%@", self.sampleId, message])];
}

- (instancetype)initWithSample:(NSString *)sampleId {
    if (!(self = [super init])) return nil;
    _sampleId = [sampleId copy];
    _title = [@"Vulkan " stringByAppendingString:sampleId];
    _view = [[NSView alloc] initWithFrame:NSZeroRect];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSString *problem = appine_vks_load();
    if (problem) {
        [self show:appine_metal_message_view(problem)];
        return self;
    }
    _vulkanView = [[AppineVulkanView alloc] initWithFrame:NSZeroRect];
    _vulkanView.owner = self;
    [self show:_vulkanView];
    // The sample starts in layoutChanged, once Emacs has given the tab a size.
    return self;
}

// Keeps the layer's pixel size in step with the view, and starts the sample
// the first time the view has a real size.
- (void)layoutChanged {
    if (!self.vulkanView.window) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.vulkanView.layer;
    CGFloat scale = self.vulkanView.window.backingScaleFactor;
    CGSize pixels = CGSizeMake(floor(self.vulkanView.bounds.size.width * scale),
                               floor(self.vulkanView.bounds.size.height * scale));
    if (pixels.width < 1 || pixels.height < 1) return;
    if (CGSizeEqualToSize(pixels, self.pixelSize)) return;
    self.pixelSize = pixels;
    layer.contentsScale = scale;
    layer.drawableSize = pixels;

    if (self.started) {
        vks.resize(pixels.width, pixels.height);
        return;
    }
    if (self.timer) return;  // already failed or starting

    char err[1024] = "";
    NSString *root = [appine_root_dir() stringByAppendingPathComponent:@"src/backends/vulkan/Vulkan-Samples"];
    if (vks.start((__bridge void *)layer, self.sampleId.UTF8String, root.fileSystemRepresentation,
                  pixels.width, pixels.height, scale, err, sizeof(err)) != 0) {
        [self fail:@(err)];
        return;
    }
    self.started = YES;
    // One frame per tick on the main thread, where the layer lives. Common
    // modes, so it keeps drawing while Emacs tracks menus or resizes.
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)tick:(NSTimer *)timer {
    if (!self.started || !self.vulkanView.window || self.vulkanView.hiddenOrHasHiddenAncestor) return;
    char err[1024] = "";
    if (vks.frame(err, sizeof(err)) != 0) [self fail:@(err)];
}

- (void)mouse:(int)action event:(NSEvent *)event {
    if (!self.started) return;
    NSPoint p = [self.vulkanView convertPoint:event.locationInWindow fromView:nil];
    CGFloat scale = self.vulkanView.window.backingScaleFactor;
    // The framework wants pixels from the top-left corner.
    vks.mouse(action, p.x * scale, (self.vulkanView.bounds.size.height - p.y) * scale);
}

- (void)cleanup {
    [self.timer invalidate];
    self.timer = nil;
    self.vulkanView.owner = nil;
    if (self.started) { vks.stop(); self.started = NO; }
}

@end

// C API export
id<AppineBackend> appine_create_vulkan_sample_backend(NSString *sampleId) {
    return [[AppineVulkanSamplesBackend alloc] initWithSample:sampleId];
}
