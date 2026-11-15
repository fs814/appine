/*
 * Filename: backend_metal_samples.m
 * Project: Appine (App in Emacs)
 * Description: Runs one of Apple's Metal sample code library samples
 *              (src/backends/metal/samples/, see the README there) in an
 *              appine tab.
 *
 * Each sample is built by samples/tools/build_sample.py into
 * build/metal-samples/<id>.bundle from its own Xcode project. This backend
 * loads the bundle and shows what the sample's app would show:
 *   - an app: its macOS storyboard's initial view controller, whose view
 *     (the MTKView plus any controls) is moved into the tab;
 *   - a command-line tool: its main(), run once, with what it prints shown
 *     in the tab and a button to run it again.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>
#import "appine_backend.h"
#import "metal/common/AppineMetalCommon.h"

// MARK: - Locations

static NSString *appine_samples_root(void) {
    Dl_info info;
    if (!dladdr((const void *)&appine_samples_root, &info) || !info.dli_fname) return nil;
    return [[@(info.dli_fname) stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent];
}

static NSString *appine_sample_bundle_path(NSString *sampleId) {
    return [NSString stringWithFormat:@"%@/build/metal-samples/%@.bundle", appine_samples_root(), sampleId];
}

// The sample's title on developer.apple.com, from catalog.json.
static NSString *appine_sample_title(NSString *sampleId) {
    static NSDictionary<NSString *, NSString *> *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSString *path = [appine_samples_root() stringByAppendingPathComponent:@"src/backends/metal/samples/catalog.json"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        for (NSDictionary *category in catalog[@"categories"])
            for (NSDictionary *sample in category[@"samples"])
                if (sample[@"id"] && sample[@"title"]) map[sample[@"id"]] = sample[@"title"];
        titles = map;
    });
    return titles[sampleId];
}

// MARK: - Resource lookups that default to the main bundle

// Samples pass bundle:nil to MTKTextureLoader, which means Emacs.app. While
// a sample is the most recently opened one, nil means its bundle instead.
static NSBundle *g_current_sample_bundle = nil;
static id (*g_original_texture_by_name)(id, SEL, NSString *, CGFloat, NSBundle *, NSDictionary *, NSError **);

static id appine_texture_by_name(id self, SEL _cmd, NSString *name, CGFloat scale, NSBundle *bundle,
                                 NSDictionary *options, NSError **error) {
    return g_original_texture_by_name(self, _cmd, name, scale, bundle ?: g_current_sample_bundle ?: NSBundle.mainBundle,
                                      options, error);
}

// Samples written with metal-cpp (C++) reach +[NSBundle mainBundle] and
// -[MTLDevice newDefaultLibrary] through the Objective-C runtime, so the
// build cannot rename those calls as it does in Objective-C. These two
// replacements answer with the sample's bundle when, and only when, the
// caller's code is inside a loaded sample bundle (found from the return
// address: objc_msgSend tail-calls, so it is the caller's). Everyone else,
// Emacs included, gets the original answer.
static NSMutableDictionary<NSValue *, NSBundle *> *g_sample_images;  // image base -> bundle

static NSBundle *appine_sample_for_address(const void *address) {
    if (!g_sample_images.count) return nil;
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fbase) return nil;
    @synchronized (g_sample_images) {
        return g_sample_images[[NSValue valueWithPointer:info.dli_fbase]];
    }
}

static id (*g_original_main_bundle)(id, SEL);
static id appine_main_bundle(id self, SEL _cmd) {
    NSBundle *sample = appine_sample_for_address(__builtin_return_address(0));
    return sample ?: g_original_main_bundle(self, _cmd);
}

static NSMutableDictionary<NSString *, NSValue *> *g_original_default_library;  // class name -> IMP
// "new" method family: the caller owns the result, so it is returned retained.
typedef id (*appine_new_imp)(id, SEL) __attribute__((ns_returns_retained));
static id appine_default_library(id self, SEL _cmd) __attribute__((ns_returns_retained));
static id appine_default_library(id self, SEL _cmd) {
    NSBundle *sample = appine_sample_for_address(__builtin_return_address(0));
    if (sample) return [(id<MTLDevice>)self newDefaultLibraryWithBundle:sample error:nil];
    appine_new_imp original = (appine_new_imp)[g_original_default_library[NSStringFromClass([self class])] pointerValue];
    return original ? original(self, _cmd) : nil;
}

static void appine_install_bundle_redirects(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_sample_images = [NSMutableDictionary dictionary];
        g_original_default_library = [NSMutableDictionary dictionary];
        Method m = class_getInstanceMethod(MTKTextureLoader.class,
                                           @selector(newTextureWithName:scaleFactor:bundle:options:error:));
        if (m) g_original_texture_by_name = (void *)method_setImplementation(m, (IMP)appine_texture_by_name);
        Method mb = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        g_original_main_bundle = (void *)method_setImplementation(mb, (IMP)appine_main_bundle);
        for (id<MTLDevice> device in MTLCopyAllDevices()) {
            Class cls = [device class];
            NSString *key = NSStringFromClass(cls);
            if (g_original_default_library[key]) continue;
            Method dl = class_getInstanceMethod(cls, @selector(newDefaultLibrary));
            if (!dl) continue;
            // Replace on this very class, so a superclass's method is not touched.
            IMP original = method_getImplementation(dl);
            if (!class_addMethod(cls, @selector(newDefaultLibrary), (IMP)appine_default_library, method_getTypeEncoding(dl)))
                method_setImplementation(dl, (IMP)appine_default_library);
            g_original_default_library[key] = [NSValue valueWithPointer:(void *)original];
        }
    });
}

static void appine_register_sample_image(NSBundle *bundle, const void *symbol) {
    Dl_info info;
    if (symbol && dladdr(symbol, &info) && info.dli_fbase) {
        @synchronized (g_sample_images) {
            g_sample_images[[NSValue valueWithPointer:info.dli_fbase]] = bundle;
        }
    }
}

// MARK: - Command-line samples

// Runs MAIN with stdout and stderr captured. The descriptors are process-wide,
// so runs are serialised, and Emacs's own output is captured meanwhile.
static NSString *appine_run_cli(int (*mainFn)(int, char **), NSString *name, int *status) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"appine-sample-%d.txt", getpid()]];
    fflush(stdout); fflush(stderr);
    int saved_out = dup(STDOUT_FILENO), saved_err = dup(STDERR_FILENO);
    FILE *capture = fopen(path.fileSystemRepresentation, "w+");
    dup2(fileno(capture), STDOUT_FILENO);
    dup2(fileno(capture), STDERR_FILENO);

    char *argv[] = { (char *)name.UTF8String, NULL };
    @try {
        *status = mainFn(1, argv);
    } @catch (NSException *e) {
        fprintf(stderr, "\nUncaught exception: %s\n", e.reason.UTF8String);
        *status = -1;
    }

    fflush(stdout); fflush(stderr);
    dup2(saved_out, STDOUT_FILENO); dup2(saved_err, STDERR_FILENO);
    close(saved_out); close(saved_err);
    fclose(capture);
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [lock unlock];
    return text;
}

// An exported C function of a loaded sample bundle, or NULL.
static void *appine_bundle_function(NSBundle *bundle, const char *name) {
    void *handle = dlopen(bundle.executablePath.fileSystemRepresentation, RTLD_NOLOAD | RTLD_NOW);
    return handle ? dlsym(handle, name) : NULL;
}

// MARK: - Backend

@interface AppineMetalSampleBackend : NSObject <AppineBackend>
@property (nonatomic, strong) NSView *view;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *sampleId;
@property (nonatomic, strong) NSBundle *bundle;
@property (nonatomic, strong) id controller;           // what the storyboard made
@property (nonatomic, strong) NSViewController *content;
@property (nonatomic, strong) NSTextView *output;      // command-line samples
@property (nonatomic) int (*cliMain)(int, char **);
@end

@implementation AppineMetalSampleBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

- (void)show:(NSView *)content {
    for (NSView *old in [self.view.subviews copy]) [old removeFromSuperview];
    content.frame = self.view.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    content.translatesAutoresizingMaskIntoConstraints = YES;
    [self.view addSubview:content];
}

- (void)fail:(NSString *)message {
    NSLog(@"[appine-metal-sample] %@: %@", self.sampleId, message);
    [self show:appine_metal_message_view([NSString stringWithFormat:@"%@\n\n%@", self.sampleId, message])];
}

- (instancetype)initWithSample:(NSString *)sampleId title:(NSString *)title {
    if (!(self = [super init])) return nil;
    _sampleId = [sampleId copy];
    _title = title.length ? [title copy] : (appine_sample_title(sampleId) ?: [sampleId copy]);
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSString *path = appine_sample_bundle_path(sampleId);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self fail:[NSString stringWithFormat:@"Not built yet. In %@ run:\n  make metal-samples", appine_samples_root()]];
        return self;
    }
    _bundle = [NSBundle bundleWithPath:path];
    NSError *error = nil;
    if (![_bundle loadAndReturnError:&error]) {
        [self fail:[@"Cannot load the sample:\n" stringByAppendingString:error.localizedDescription]];
        return self;
    }
    appine_install_bundle_redirects();
    g_current_sample_bundle = _bundle;
    void (*activate)(void) = appine_bundle_function(_bundle, "appine_sample_activate");
    appine_register_sample_image(_bundle, (const void *)activate);
    if (activate) activate();

    @try {
        if ([[_bundle objectForInfoDictionaryKey:@"AppineSampleCLI"] boolValue]) {
            [self startCommandLine];
        } else {
            [self startApp];
        }
    } @catch (NSException *e) {
        [self fail:[NSString stringWithFormat:@"The sample stopped: %@", e.reason]];
    }
    return self;
}

- (void)startApp {
    NSString *name = [_bundle objectForInfoDictionaryKey:@"NSMainStoryboardFile"];
    if (!name) {
        [self fail:@"This sample has no macOS storyboard, so appine does not know which view to show."];
        return;
    }
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:name bundle:_bundle];
    id initial = [storyboard instantiateInitialController];
    NSViewController *vc = nil;
    if ([initial isKindOfClass:NSWindowController.class]) {
        NSWindowController *wc = initial;
        vc = wc.contentViewController;
        if (!vc) {
            // A window whose content is a plain view rather than a controller.
            NSView *v = wc.window.contentView;
            wc.window.contentView = [[NSView alloc] init];
            _controller = wc;
            [self show:v];
            return;
        }
        // Take the view out of the (never shown) window.
        (void)vc.view;
        wc.window.contentViewController = nil;
    } else if ([initial isKindOfClass:NSViewController.class]) {
        vc = initial;
    }
    if (!vc) {
        [self fail:@"The sample's storyboard has no view controller to show."];
        return;
    }
    _controller = initial;
    _content = vc;
    [vc viewWillAppear];
    [self show:vc.view];
    [vc viewDidAppear];
}

- (void)startCommandLine {
    _cliMain = (int (*)(int, char **))appine_bundle_function(_bundle, "appine_sample_main");
    if (!_cliMain) {
        [self fail:@"The sample's entry point is missing; rebuild it."];
        return;
    }
    NSButton *again = [NSButton buttonWithTitle:@"Run again" target:self action:@selector(runCommandLine:)];
    again.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _output = scroll.documentView;
    _output.editable = NO;
    _output.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _output.textContainerInset = NSMakeSize(10, 8);

    NSView *box = [[NSView alloc] init];
    [box addSubview:again];
    [box addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [again.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [again.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
        [scroll.topAnchor constraintEqualToAnchor:again.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
    ]];
    [self show:box];
    [self runCommandLine:nil];
}

- (void)runCommandLine:(id)sender {
    self.output.string = @"Running...";
    int (*mainFn)(int, char **) = self.cliMain;
    NSString *name = self.sampleId;
    // Off the main thread: some tools wait on the GPU or run for a while.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = 0;
        NSString *text = appine_run_cli(mainFn, name, &status);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.output.string = [NSString stringWithFormat:@"%@\n[exit status %d]\n", text, status];
        });
    });
}

static void appine_pause_metal_views(NSView *view) {
    if ([view isKindOfClass:MTKView.class]) {
        ((MTKView *)view).paused = YES;
        ((MTKView *)view).delegate = nil;
    }
    for (NSView *sub in view.subviews) appine_pause_metal_views(sub);
}

- (void)cleanup {
    if (self.content) [self.content viewWillDisappear];
    appine_pause_metal_views(self.view);
    for (NSView *v in [self.view.subviews copy]) [v removeFromSuperview];
    if (self.content) [self.content viewDidDisappear];
    self.content = nil;
    self.controller = nil;
}

@end

// C API export
id<AppineBackend> appine_create_metal_sample_backend(NSString *sampleId, NSString *title) {
    return [[AppineMetalSampleBackend alloc] initWithSample:sampleId title:title];
}
