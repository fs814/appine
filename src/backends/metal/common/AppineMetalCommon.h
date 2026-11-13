/*
 * Filename: AppineMetalCommon.h
 * Project: Appine (App in Emacs)
 * Description: What the Metal sample backends (triangle/, raytracing/) share
 *              to run inside Emacs instead of in their own apps. See
 *              ../README.md.
 */
#ifndef APPINE_METAL_COMMON_H
#define APPINE_METAL_COMMON_H

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

// The samples check their Metal objects with NSAssert. Inside Emacs a failed
// assert would throw into Emacs, so a failed check is logged instead; the
// backends verify the device and shaders up front so the samples never get
// that far.
#define APPINE_METAL_ASSERT(condition, ...) do { \
    if (!(condition)) { NSLog(@"[appine-metal] %@", [NSString stringWithFormat:__VA_ARGS__]); } \
} while (0)

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

/// The samples load their shaders with -[MTLDevice newDefaultLibrary], which
/// reads default.metallib from the app bundle. Emacs has none, so each
/// sample's ShaderTypes.h + Shaders.metal are embedded in the dylib as source
/// (see the Makefile) and compiled here at first use. The library is cached
/// per device and KEY. Returns nil, after logging the compiler error, when the
/// source does not compile.
id<MTLLibrary> _Nullable appine_metal_library_from_source(id<MTLDevice> device,
                                                          NSString *key,
                                                          const unsigned char *source,
                                                          unsigned int length,
                                                          MTLCompileOptions *_Nullable options);

/// A view with a centered, gray MESSAGE: what a backend shows instead of its
/// Metal view when this Mac cannot run the sample.
NSView *appine_metal_message_view(NSString *message);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif /* APPINE_METAL_COMMON_H */
