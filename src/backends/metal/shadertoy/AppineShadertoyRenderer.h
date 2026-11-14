/*
 * Filename: AppineShadertoyRenderer.h
 * Project: Appine (App in Emacs)
 * Description: Runs a Shadertoy shader (its JSON form) with Metal: Common,
 *              Buffer A-D and Image passes. See README.md in this directory.
 */
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppineShadertoyRenderer : NSObject <MTKViewDelegate>

/// The shader's name from its JSON, or nil.
@property (nonatomic, readonly, nullable) NSString *shaderName;
/// Things the shader uses that are replaced by stand-ins (textures, audio...).
@property (nonatomic, readonly) NSArray<NSString *> *warnings;

/// Translates and compiles every pass; slow, and safe to call off the main
/// thread. JSON is what Shadertoy's API or its export gives: {"Shader":{...}},
/// [{...}] or {"info":..., "renderpass":[...]}.
/// Returns nil and sets ERROR when the shader cannot be built.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                   json:(id)json
                                  error:(NSString *_Nullable *_Nonnull)error;

/// Wraps bare GLSL (a file with just mainImage) as a one-pass shader.
+ (NSDictionary *)jsonForImageCode:(NSString *)code name:(NSString *)name;

/// Mouse position in pixels, origin bottom-left, as Shadertoy's iMouse wants.
- (void)mouseAt:(CGPoint)pixel down:(BOOL)down clicked:(BOOL)clicked;

@end

NS_ASSUME_NONNULL_END
