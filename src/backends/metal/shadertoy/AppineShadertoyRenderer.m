/*
 * Filename: AppineShadertoyRenderer.m
 * Project: Appine (App in Emacs)
 * Description: Metal renderer for Shadertoy shaders. See the header.
 */
#import "AppineShadertoyRenderer.h"
#import "AppineShadertoyTranslator.h"
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, STInputKind) { STInputNone, STInputBuffer, STInputTexture };

@interface STInput : NSObject
@property (nonatomic) STInputKind kind;
@property (nonatomic) NSInteger bufferIndex;          // into the renderer's buffer passes
@property (nonatomic, strong) id<MTLTexture> texture; // STInputTexture
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic) BOOL wantsMipmaps;
@end
@implementation STInput
@end

@interface STPass : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *outputId;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) NSArray<STInput *> *inputs;  // always 4
@property (nonatomic, strong) NSMutableArray<id<MTLTexture>> *targets;  // 2 for buffers, 1 for Image
@property (nonatomic) NSUInteger current;  // index of the target last rendered
@property (nonatomic) BOOL mipmapped;      // some pass samples this buffer with mipmaps
@end
@implementation STPass
@end

// Vertex shader shared by all passes, and the final copy to the view. Passes
// render with Metal's top-left origin as if it were Shadertoy's bottom-left
// (see the translator), so the copy flips rows.
static NSString *const kSharedMSL =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; };\n"
    "vertex VOut st_vertex(uint vid [[vertex_id]]) {\n"
    "    float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;\n"
    "}\n"
    "fragment float4 st_present(VOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {\n"
    "    uint2 c = uint2(in.pos.xy);\n"
    "    c.y = image.get_height() - 1 - min(c.y, image.get_height() - 1);\n"
    "    return float4(image.read(c).rgb, 1.0);\n"
    "}\n";

@implementation AppineShadertoyRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLFunction> _vertex;
    id<MTLRenderPipelineState> _present;
    MTLPixelFormat _format;
    id<MTLTexture> _black;  // bound to channels with nothing attached

    NSArray<STPass *> *_buffers;  // Buffer A..D, in run order
    STPass *_image;
    NSMutableArray<NSString *> *_warnings;

    CGSize _size;
    CFTimeInterval _start, _last;
    int32_t _frame;
    float _mouse[4];
}

+ (NSDictionary *)jsonForImageCode:(NSString *)code name:(NSString *)name {
    return @{ @"info": @{ @"name": name },
              @"renderpass": @[ @{ @"type": @"image", @"name": @"Image", @"code": code,
                                   @"inputs": @[], @"outputs": @[] } ] };
}

- (NSArray<NSString *> *)warnings { return _warnings; }

// MARK: - Building

static NSString *st_string(id value) {
    return [value isKindOfClass:NSString.class] ? value
         : [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : @"";
}

- (instancetype)initWithDevice:(id<MTLDevice>)device json:(id)json error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _device = device;
    _queue = [device newCommandQueue];
    _warnings = [NSMutableArray array];
    // Shadertoy buffers are float textures; 32-bit where it can be filtered.
    _format = device.supports32BitFloatFiltering ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA16Float;

    // Accept {"Shader":{...}}, [{...}] and {...}.
    if ([json isKindOfClass:NSArray.class]) json = [json firstObject];
    if ([json isKindOfClass:NSDictionary.class] && json[@"Shader"]) json = json[@"Shader"];
    NSArray *passes = [json isKindOfClass:NSDictionary.class] ? json[@"renderpass"] : nil;
    if (![passes isKindOfClass:NSArray.class] || passes.count == 0) {
        NSString *apiError = [json isKindOfClass:NSDictionary.class] ? st_string(json[@"Error"]) : @"";
        *error = apiError.length ? [@"Shadertoy: " stringByAppendingString:apiError]
                                 : @"Not a Shadertoy shader: no \"renderpass\" list in the JSON.";
        return nil;
    }
    _shaderName = st_string([json valueForKeyPath:@"info.name"]);

    NSError *nsError = nil;
    id<MTLLibrary> shared = [device newLibraryWithSource:kSharedMSL options:nil error:&nsError];
    if (!shared) { *error = nsError.localizedDescription; return nil; }
    _vertex = [shared newFunctionWithName:@"st_vertex"];

    MTLTextureDescriptor *blackDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:1 height:1 mipmapped:NO];
    _black = [device newTextureWithDescriptor:blackDesc];
    const uint8_t zero[4] = {0, 0, 0, 0};
    [_black replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:4];

    // Sort the passes: Common is text, buffers run in name order, then Image.
    NSString *common = @"";
    NSMutableArray<NSDictionary *> *bufferJSON = [NSMutableArray array];
    NSDictionary *imageJSON = nil;
    for (NSDictionary *pass in passes) {
        NSString *type = st_string(pass[@"type"]);
        if ([type isEqualToString:@"common"]) common = st_string(pass[@"code"]);
        else if ([type isEqualToString:@"buffer"]) [bufferJSON addObject:pass];
        else if ([type isEqualToString:@"image"]) imageJSON = pass;
        else [_warnings addObject:[NSString stringWithFormat:@"%@ pass (%@) is not supported and is skipped", type, st_string(pass[@"name"])]];
    }
    if (!imageJSON) { *error = @"The shader has no Image pass."; return nil; }
    [bufferJSON sortUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [st_string(a[@"name"]) compare:st_string(b[@"name"])];
    }];

    NSMutableArray<STPass *> *buffers = [NSMutableArray array];
    for (NSDictionary *pass in bufferJSON) {
        STPass *p = [STPass new];
        p.name = st_string(pass[@"name"]);
        p.outputId = st_string([[pass[@"outputs"] firstObject] valueForKey:@"id"]);
        [buffers addObject:p];
    }
    _buffers = buffers;
    _image = [STPass new];
    _image.name = @"Image";

    NSArray<NSDictionary *> *allJSON = [bufferJSON arrayByAddingObject:imageJSON];
    NSArray<STPass *> *all = [buffers arrayByAddingObject:_image];
    for (NSUInteger i = 0; i < all.count; i++) {
        if (![self buildPass:all[i] json:allJSON[i] common:common error:error]) return nil;
    }

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = _vertex;
    d.fragmentFunction = [shared newFunctionWithName:@"st_present"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _present = [device newRenderPipelineStateWithDescriptor:d error:&nsError];
    if (!_present) { *error = nsError.localizedDescription; return nil; }

    _start = _last = CACurrentMediaTime();
    return self;
}

- (BOOL)buildPass:(STPass *)pass json:(NSDictionary *)json common:(NSString *)common error:(NSString **)error {
    NSMutableArray<STInput *> *inputs = [NSMutableArray array];
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (int i = 0; i < 4; i++) { [inputs addObject:[STInput new]]; [types addObject:@"sampler2D"]; }

    for (NSDictionary *in in ([json[@"inputs"] isKindOfClass:NSArray.class] ? json[@"inputs"] : @[])) {
        NSInteger channel = [in[@"channel"] integerValue];
        if (channel < 0 || channel > 3) continue;
        STInput *input = inputs[channel];
        NSString *kind = st_string(in[@"ctype"] ?: in[@"type"]);
        NSString *source = st_string(in[@"src"] ?: in[@"filepath"]);
        NSDictionary *sampler = [in[@"sampler"] isKindOfClass:NSDictionary.class] ? in[@"sampler"] : @{};
        NSString *filter = st_string(sampler[@"filter"]);
        input.wantsMipmaps = [filter isEqualToString:@"mipmap"];

        if ([kind isEqualToString:@"buffer"]) {
            // By output id; the site's own export names the file bufferNN instead.
            NSString *wanted = st_string(in[@"id"]);
            NSInteger found = NSNotFound;
            for (NSUInteger b = 0; b < _buffers.count; b++)
                if (wanted.length && [_buffers[b].outputId isEqualToString:wanted]) found = b;
            NSRange r = [source rangeOfString:@"buffer0"];
            if (found == NSNotFound && r.location != NSNotFound && NSMaxRange(r) < source.length)
                found = [source characterAtIndex:NSMaxRange(r)] - '0';
            if (found == NSNotFound || found < 0 || found >= (NSInteger)_buffers.count) {
                [_warnings addObject:[NSString stringWithFormat:@"%@ iChannel%ld: buffer not found, using black", pass.name, (long)channel]];
            } else {
                input.kind = STInputBuffer;
                input.bufferIndex = found;
                if (input.wantsMipmaps) _buffers[found].mipmapped = YES;
            }
        } else if ([kind isEqualToString:@"cubemap"]) {
            types[channel] = @"samplerCube";
            input.kind = STInputTexture;
            input.texture = [self standInWithType:MTLTextureTypeCube size:64];
            [_warnings addObject:[NSString stringWithFormat:@"%@ iChannel%ld: cubemap replaced by a stand-in", pass.name, (long)channel]];
        } else if ([kind isEqualToString:@"volume"]) {
            types[channel] = @"sampler3D";
            input.kind = STInputTexture;
            input.texture = [self standInWithType:MTLTextureType3D size:32];
            [_warnings addObject:[NSString stringWithFormat:@"%@ iChannel%ld: volume texture replaced by noise", pass.name, (long)channel]];
        } else if ([kind isEqualToString:@"texture"]) {
            input.kind = STInputTexture;
            input.texture = [self standInWithType:MTLTextureType2D size:256];
            [_warnings addObject:[NSString stringWithFormat:@"%@ iChannel%ld: texture %@ replaced by noise", pass.name, (long)channel, source.lastPathComponent]];
        } else if (kind.length) {
            // keyboard, music, musicstream, mic, video, webcam: black.
            [_warnings addObject:[NSString stringWithFormat:@"%@ iChannel%ld: %@ input is not supported (reads as black)", pass.name, (long)channel, kind]];
        }

        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        BOOL nearest = [filter isEqualToString:@"nearest"];
        sd.minFilter = sd.magFilter = nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sd.mipFilter = input.wantsMipmaps ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNotMipmapped;
        MTLSamplerAddressMode wrap = [st_string(sampler[@"wrap"]) isEqualToString:@"repeat"]
            ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = wrap;
        input.sampler = [_device newSamplerStateWithDescriptor:sd];
    }
    // Channels nothing is attached to still need something bound.
    for (STInput *input in inputs) {
        if (!input.sampler) input.sampler = [_device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    }
    pass.inputs = inputs;

    NSString *msl = appine_shadertoy_translate(common, st_string(json[@"code"]), types, pass.name, error);
    if (!msl) return NO;

    NSError *nsError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:msl options:nil error:&nsError];
    if (!library) {
        *error = [NSString stringWithFormat:@"%@: the translated Metal shader did not compile:\n%@", pass.name, nsError.localizedDescription];
        return NO;
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.label = pass.name;
    d.vertexFunction = _vertex;
    d.fragmentFunction = [library newFunctionWithName:@"main0"];
    d.colorAttachments[0].pixelFormat = _format;
    pass.pipeline = [_device newRenderPipelineStateWithDescriptor:d error:&nsError];
    if (!pass.pipeline) {
        *error = [NSString stringWithFormat:@"%@: %@", pass.name, nsError.localizedDescription];
        return NO;
    }
    return YES;
}

// Shadertoy's own media (textures, cubemaps, volumes) are not bundled; a
// fixed grey noise stands in, so shaders that only need "some texture" work.
- (id<MTLTexture>)standInWithType:(MTLTextureType)type size:(NSUInteger)n {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = td.height = n;
    td.depth = type == MTLTextureType3D ? n : 1;
    td.mipmapLevelCount = type == MTLTextureType2D ? 1 + (NSUInteger)floor(log2((double)n)) : 1;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];

    NSUInteger layers = type == MTLTextureTypeCube ? 6 : 1, count = n * n * td.depth * 4;
    uint8_t *pixels = malloc(count);
    uint32_t seed = 0x9E3779B9u;
    for (NSUInteger layer = 0; layer < layers; layer++) {
        for (NSUInteger i = 0; i < count; i++) {
            seed = seed * 1664525u + 1013904223u;
            pixels[i] = (i % 4 == 3) ? 255 : (uint8_t)(seed >> 24);
        }
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, n, n, td.depth) mipmapLevel:0 slice:layer
                     withBytes:pixels bytesPerRow:n * 4 bytesPerImage:n * n * 4];
    }
    free(pixels);
    if (td.mipmapLevelCount > 1) {
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit generateMipmapsForTexture:texture];
        [blit endEncoding];
        [cb commit];
    }
    return texture;
}

// MARK: - Input

- (void)mouseAt:(CGPoint)p down:(BOOL)down clicked:(BOOL)clicked {
    // xy: position while the button is down. zw: where it was pressed; z > 0
    // while down, w > 0 only on the frame of the press.
    if (clicked) { _mouse[2] = p.x; _mouse[3] = p.y; }
    if (down) { _mouse[0] = p.x; _mouse[1] = p.y; }
    _mouse[2] = down ? fabsf(_mouse[2]) : -fabsf(_mouse[2]);
    _mouse[3] = clicked ? fabsf(_mouse[3]) : -fabsf(_mouse[3]);
}

// MARK: - Drawing

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // An appine view starts at zero size before Emacs places it.
    if (size.width < 1 || size.height < 1) return;
    if (CGSizeEqualToSize(size, _size)) return;
    _size = size;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    for (STPass *pass in [_buffers arrayByAddingObject:_image]) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_format
                                                                                      width:size.width
                                                                                     height:size.height
                                                                                  mipmapped:pass.mipmapped];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        pass.targets = [NSMutableArray array];
        for (int i = 0; i < (pass == _image ? 1 : 2); i++) {
            id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
            [pass.targets addObject:texture];
            // Buffers start black, as on Shadertoy.
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        pass.current = 0;
    }
    [cb commit];
    // A resize restarts the shader, like Shadertoy's rewind.
    _frame = 0;
    _start = _last = CACurrentMediaTime();
}

- (void)encodePass:(STPass *)pass into:(id<MTLCommandBuffer>)cb uniforms:(AppineShadertoyUniforms)u {
    // Buffers ping-pong: render into the other target while reading the last.
    NSUInteger targetIndex = pass.targets.count == 2 ? 1 - pass.current : 0;
    id<MTLTexture> target = pass.targets[targetIndex];

    id<MTLTexture> textures[4] = { nil, nil, nil, nil };
    for (int i = 0; i < 4; i++) {
        STInput *input = pass.inputs[i];
        if (input.kind == STInputBuffer) {
            STPass *source = _buffers[input.bufferIndex];
            textures[i] = source.targets[source.current];
        } else if (input.kind == STInputTexture) {
            textures[i] = input.texture;
        }
        if (textures[i]) {
            u.iChannelResolution[i][0] = textures[i].width;
            u.iChannelResolution[i][1] = textures[i].height;
            u.iChannelResolution[i][2] = textures[i].depth;
        }
        u.iChannelTime[i][0] = u.iTime;
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    enc.label = pass.name;
    [enc setRenderPipelineState:pass.pipeline];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:AppineShadertoyUniformBufferIndex];
    for (int i = 0; i < 4; i++) {
        // Unattached and unsupported channels read as black.
        [enc setFragmentTexture:textures[i] ?: _black atIndex:i];
        [enc setFragmentSamplerState:pass.inputs[i].sampler atIndex:i];
    }
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    if (pass.mipmapped) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit generateMipmapsForTexture:target];
        [blit endEncoding];
    }
    pass.current = targetIndex;
}

- (void)drawInMTKView:(MTKView *)view {
    // The view is created already sized, and then MetalKit sends no size
    // change; so the size is checked here (a no-op when it has not changed).
    [self mtkView:view drawableSizeWillChange:view.drawableSize];
    if (!_image.targets.count) return;  // no size yet

    CFTimeInterval now = CACurrentMediaTime();
    AppineShadertoyUniforms u = {0};
    u.iResolution[0] = _size.width; u.iResolution[1] = _size.height; u.iResolution[2] = 1.0f;
    u.iTime = now - _start;
    u.iTimeDelta = now - _last;
    u.iFrameRate = u.iTimeDelta > 0 ? 1.0f / u.iTimeDelta : 60.0f;
    u.iFrame = _frame;
    u.iSampleRate = 44100.0f;
    memcpy(u.iMouse, _mouse, sizeof(_mouse));
    NSDateComponents *date = [[NSCalendar currentCalendar]
        components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
                   NSCalendarUnitMinute | NSCalendarUnitSecond | NSCalendarUnitNanosecond
          fromDate:[NSDate date]];
    u.iDate[0] = date.year; u.iDate[1] = date.month - 1; u.iDate[2] = date.day;
    u.iDate[3] = date.hour * 3600 + date.minute * 60 + date.second + date.nanosecond * 1e-9;
    _last = now;
    _frame++;
    // The "pressed this frame" sign of iMouse.w lasts one frame.
    _mouse[3] = -fabsf(_mouse[3]);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    for (STPass *pass in _buffers) [self encodePass:pass into:cb uniforms:u];
    [self encodePass:_image into:cb uniforms:u];

    MTLRenderPassDescriptor *rp = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (rp && drawable) {
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:_present];
        [enc setFragmentTexture:_image.targets[0] atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb presentDrawable:drawable];
    }
    [cb commit];
}

@end
