/*
 * Filename: backend_metal_shadertoy.m
 * Project: Appine (App in Emacs)
 * Description: A Shadertoy shader in an appine tab, translated from GLSL to
 *              Metal at runtime (src/backends/metal/shadertoy/, see the
 *              README there).
 *
 * SOURCE is one of:
 *   - a file: Shadertoy JSON (API or export format), or bare GLSL with a
 *     mainImage function;
 *   - a Shadertoy link or shader ID. That is fetched through Shadertoy's
 *     official API (https://www.shadertoy.com/howto#q2), which needs the
 *     user's API key and only serves shaders published as "public + API".
 *     Fetched shaders are cached in ~/Library/Caches/appine/shadertoy/.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "appine_backend.h"
#import "metal/common/AppineMetalCommon.h"
#import "metal/shadertoy/AppineShadertoyRenderer.h"
#import "metal/shadertoy/AppineShadertoyTranslator.h"

// Set from Emacs (appine-shadertoy-api-key); kept in memory only.
static NSString *g_shadertoy_api_key = nil;

void appine_shadertoy_set_api_key(NSString *key) {
    g_shadertoy_api_key = key.length ? [key copy] : nil;
}

// MARK: - View

// Forwards the mouse to the renderer as Shadertoy's iMouse.
@interface AppineShadertoyView : MTKView
@property (nonatomic, weak) AppineShadertoyRenderer *shadertoy;
@end

@implementation AppineShadertoyView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)report:(NSEvent *)event down:(BOOL)down clicked:(BOOL)clicked {
    // View coordinates already have Shadertoy's bottom-left origin.
    NSPoint p = [self convertPointToBacking:[self convertPoint:event.locationInWindow fromView:nil]];
    [self.shadertoy mouseAt:p down:down clicked:clicked];
}
- (void)mouseDown:(NSEvent *)event { [self report:event down:YES clicked:YES]; }
- (void)mouseDragged:(NSEvent *)event { [self report:event down:YES clicked:NO]; }
- (void)mouseUp:(NSEvent *)event { [self report:event down:NO clicked:NO]; }
@end

// MARK: - Backend

@interface AppineMetalShadertoyBackend : NSObject <AppineBackend>
@property (nonatomic, strong) NSView *view;  // container: a message, then the Metal view
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) AppineShadertoyView *metalView;
@property (nonatomic, strong) AppineShadertoyRenderer *renderer;
@property (nonatomic) BOOL closed;
@end

@implementation AppineMetalShadertoyBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

- (void)show:(NSView *)content {
    for (NSView *old in [self.view.subviews copy]) [old removeFromSuperview];
    content.frame = self.view.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:content];
}

- (void)showMessage:(NSString *)message {
    [self show:appine_metal_message_view(message)];
}

// "https://www.shadertoy.com/view/XsXXDn", "shadertoy.com/embed/XsXXDn?..." or
// "XsXXDn" -> "XsXXDn"; nil when SOURCE is none of these.
static NSString *appine_shadertoy_id(NSString *source) {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"^(?:(?:https?://)?(?:www\\.)?shadertoy\\.com/(?:view|embed)/)?([A-Za-z0-9]{6})(?:[/?#].*)?$"
                             options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:source options:0 range:NSMakeRange(0, source.length)];
    return m ? [source substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSURL *appine_shadertoy_cache_file(NSString *shaderId) {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:@"appine/shadertoy" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:[shaderId stringByAppendingPathExtension:@"json"]];
}

// The shader's JSON for SOURCE, or nil with ERROR. Runs off the main thread.
static id appine_shadertoy_load(NSString *source, NSString **error) {
    NSString *path = source.stringByExpandingTildeInPath;
    NSData *data = nil;
    NSString *shaderId = nil;

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        data = [NSData dataWithContentsOfFile:path];
    } else if ((shaderId = appine_shadertoy_id(source))) {
        NSURL *cache = appine_shadertoy_cache_file(shaderId);
        data = [NSData dataWithContentsOfURL:cache];
        if (!data) {
            if (!g_shadertoy_api_key) {
                *error = [NSString stringWithFormat:
                    @"Shader %@ is not cached, and fetching it needs a Shadertoy API key.\n\n"
                    "Get one at shadertoy.com/myapps and set appine-shadertoy-api-key in Emacs,\n"
                    "or save the shader's JSON to a file and open that file.", shaderId];
                return nil;
            }
            NSURLComponents *url = [NSURLComponents componentsWithString:
                [@"https://www.shadertoy.com/api/v1/shaders/" stringByAppendingString:shaderId]];
            url.queryItems = @[ [NSURLQueryItem queryItemWithName:@"key" value:g_shadertoy_api_key] ];
            __block NSData *body = nil;
            __block NSInteger status = 0;
            __block NSError *netError = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [[[NSURLSession sharedSession] dataTaskWithURL:url.URL
                                         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                body = d; netError = e;
                status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
                dispatch_semaphore_signal(done);
            }] resume];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            id json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
            if (status != 200 || ![json isKindOfClass:NSDictionary.class]) {
                *error = [NSString stringWithFormat:
                    @"Shadertoy did not return shader %@ (%@).\n\n"
                    "Its API answers only some clients (HTTP 403 means the request was refused\n"
                    "before reaching the API). Save the shader's JSON to a file and open that file.",
                    shaderId, netError ? netError.localizedDescription
                                       : [NSString stringWithFormat:@"HTTP %ld", (long)status]];
                return nil;
            }
            if (json[@"Shader"]) [body writeToURL:cache atomically:YES];  // not API errors
            return json;
        }
    } else {
        *error = [NSString stringWithFormat:@"Not a file, a Shadertoy link or a shader ID:\n%@", source];
        return nil;
    }

    if (!data) { *error = [@"Cannot read " stringByAppendingString:path]; return nil; }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (json) return json;
    // Not JSON: bare GLSL.
    NSString *code = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![code containsString:@"mainImage"]) {
        *error = [NSString stringWithFormat:@"%@ is neither Shadertoy JSON nor GLSL with a mainImage function.", path.lastPathComponent];
        return nil;
    }
    return [AppineShadertoyRenderer jsonForImageCode:code name:path.lastPathComponent];
}

- (instancetype)initWithSource:(NSString *)source {
    if (!(self = [super init])) return nil;
    _title = appine_shadertoy_id(source) ? [@"Shadertoy " stringByAppendingString:appine_shadertoy_id(source)]
                                         : source.lastPathComponent;
    _view = [[NSView alloc] initWithFrame:NSZeroRect];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        [self showMessage:@"Metal is not supported on this Mac."];
        return self;
    }
    if (!appine_shadertoy_translator_available()) {
        [self showMessage:@"This appine was built without the Vulkan SDK, which translates Shadertoy's GLSL.\n"
                           "Install it (Settings/binmac/init/vulkan-init.sh) and rebuild appine."];
        return self;
    }
    [self showMessage:[NSString stringWithFormat:@"Loading %@ ...", _title]];

    // Fetching, translating and compiling can take seconds: off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        id json = appine_shadertoy_load(source, &error);
        AppineShadertoyRenderer *renderer =
            json ? [[AppineShadertoyRenderer alloc] initWithDevice:device json:json error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.closed) return;
            if (!renderer) {
                NSLog(@"[appine-shadertoy] %@", error);
                [self showMessage:error ?: @"Could not load the shader."];
                return;
            }
            for (NSString *warning in renderer.warnings) NSLog(@"[appine-shadertoy] %@", warning);
            self.renderer = renderer;
            self.metalView = [[AppineShadertoyView alloc] initWithFrame:self.view.bounds device:device];
            self.metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
            self.metalView.shadertoy = renderer;
            // MTKView keeps its delegate weak; the backend holds the renderer.
            self.metalView.delegate = renderer;
            [self show:self.metalView];
        });
    });
    return self;
}

- (void)cleanup {
    self.closed = YES;
    self.metalView.paused = YES;
    self.metalView.delegate = nil;
    self.renderer = nil;
}

@end

// C API export
id<AppineBackend> appine_create_metal_shadertoy_backend(NSString *source) {
    return [[AppineMetalShadertoyBackend alloc] initWithSource:source];
}
