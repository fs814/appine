/*
 * Filename: AppineMetalCommon.m
 * Project: Appine (App in Emacs)
 * Description: Shared runtime support for the Metal sample backends.
 */
#import "AppineMetalCommon.h"

id<MTLLibrary> appine_metal_library_from_source(id<MTLDevice> device,
                                                NSString *key,
                                                const unsigned char *source,
                                                unsigned int length,
                                                MTLCompileOptions *options) {
    // device -> (key -> library); weak on the device so a removed GPU is not kept.
    static NSMapTable<id<MTLDevice>, NSMutableDictionary<NSString *, id<MTLLibrary>> *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });

    @synchronized (cache) {
        NSMutableDictionary<NSString *, id<MTLLibrary>> *libraries = [cache objectForKey:device];
        if (!libraries) {
            libraries = [NSMutableDictionary dictionary];
            [cache setObject:libraries forKey:device];
        }
        id<MTLLibrary> library = libraries[key];
        if (library) return library;

        NSString *text = [[NSString alloc] initWithBytes:source
                                                  length:length
                                                encoding:NSUTF8StringEncoding];
        NSError *error = nil;
        library = [device newLibraryWithSource:text
                                       options:options ?: [MTLCompileOptions new]
                                         error:&error];
        if (!library) {
            NSLog(@"[appine-metal] %@ shaders failed to compile: %@", key, error);
            return nil;
        }
        library.label = [NSString stringWithFormat:@"appine %@ shaders", key];
        libraries[key] = library;
        return library;
    }
}

NSView *appine_metal_message_view(NSString *message) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0.0;
    box.contentViewMargins = NSMakeSize(0, 0);
    box.fillColor = [NSColor windowBackgroundColor];
    box.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *label = [NSTextField wrappingLabelWithString:message];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:box.contentView.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:box.contentView.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:box.contentView.widthAnchor constant:-40],
    ]];
    return box;
}
