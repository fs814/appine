/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Renderer implementation that orchestrates the deferred geometry, irradiance, and composite passes each frame, and drives per-frame MLP training when the MPP technique is active.
*/

#import <simd/simd.h>
#import <ModelIO/ModelIO.h>

#import "Renderer.h"
#import "IrradianceTechnique.h"
#import "MathUtilities.h"
#import "ShaderTypes.h"

#define MaxBuffersInFlight 2

@implementation Renderer
{
    id<MTLDevice> _device;
    id<MTL4Compiler> _compiler;
    id<MTL4CommandQueue> _commandQueue;
    id<MTL4CommandAllocator> _commandAllocators[MaxBuffersInFlight];
    id<MTL4CommandBuffer> _commandBuffer;
    id<MTL4ArgumentTable> _argumentTable;
    id<MTLResidencySet> _residencySet;
    id<MTLSharedEvent> _sharedEvent;
    uint64_t _currentFrameIndex;

    id<MTLRenderPipelineState> _geometryPipelineState;
    id<MTLRenderPipelineState> _compositePipelineState;
    id<MTLDepthStencilState> _depthState;

    id<MTLTexture> _envMap;
    id<MTLTexture> _normalMap;
    id<MTLTexture> _armMap;

    id<MTLTexture> _normalBuffer;
    id<MTLTexture> _armBuffer;
    id<MTLTexture> _depthBuffer;

    MTLVertexDescriptor *_sphereVertexDescriptor;
    MTKMesh *_sphereMesh;
    id<MTLBuffer> _dynamicUniformBuffer[MaxBuffersInFlight];
    uint8_t _uniformBufferIndex;
    matrix_float4x4 _projectionMatrix;

    id<IrradianceTechnique> _techniques[3];
    id<MTLTensor> _outputTensor;
    id<MTL4CounterHeap> _irradianceCounterHeap;

    uint64_t _statsTicksPerSecond;
    CFAbsoluteTime _statsLastTime;
    uint32_t _statsFrameCount;
    double _statsTrainTimeAccum;
    double _statsIrradianceTimeAccum;
}

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
{
    self = [super init];
    if(self)
    {
        _device = view.device;
        _cameraDistance = 3.0f;
        _irradianceMode = IrradianceModeMPP;
        [self loadMetalWithView:view];
        [self loadAssets];
        [self loadEnvMap];
    }
    return self;
}

- (void)loadMetalWithView:(nonnull MTKView *)view;
{
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

    _sphereVertexDescriptor = [[MTLVertexDescriptor alloc] init];

    _sphereVertexDescriptor.attributes[VertexAttributePosition].format = MTLVertexFormatFloat3;
    _sphereVertexDescriptor.attributes[VertexAttributePosition].bufferIndex = BufferIndexMeshPositions;
    _sphereVertexDescriptor.layouts[BufferIndexMeshPositions].stride = 12;

    _sphereVertexDescriptor.attributes[VertexAttributeNormal].format = MTLVertexFormatFloat3;
    _sphereVertexDescriptor.attributes[VertexAttributeNormal].bufferIndex = BufferIndexMeshNormals;
    _sphereVertexDescriptor.layouts[BufferIndexMeshNormals].stride = 12;

    _sphereVertexDescriptor.attributes[VertexAttributeTexcoord].format = MTLVertexFormatFloat2;
    _sphereVertexDescriptor.attributes[VertexAttributeTexcoord].bufferIndex = BufferIndexMeshTexcoords;
    _sphereVertexDescriptor.layouts[BufferIndexMeshTexcoords].stride = 8;

    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];

    NSError *error;
    _compiler = [_device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    NSAssert(_compiler, @"Failed to create compiler: %@", error);

    // Geometry pipeline
    {
        MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
        vf.library = defaultLibrary;
        vf.name = @"geometryVertexShader";
        MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
        ff.library = defaultLibrary;
        ff.name = @"geometryFragmentShader";

        MTL4RenderPipelineDescriptor *desc = [MTL4RenderPipelineDescriptor new];
        desc.label = @"GeometryPipeline";
        desc.vertexFunctionDescriptor = vf;
        desc.fragmentFunctionDescriptor = ff;
        desc.vertexDescriptor = _sphereVertexDescriptor;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        desc.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;

        _geometryPipelineState = [_compiler newRenderPipelineStateWithDescriptor:desc
                                                           compilerTaskOptions:nil
                                                                         error:&error];
        NSAssert(_geometryPipelineState, @"Failed to create geometry pipeline: %@", error);
    }

    // Counter heap for GPU timing.
    {
        MTL4CounterHeapDescriptor *desc = [MTL4CounterHeapDescriptor new];
        desc.type  = MTL4CounterHeapTypeTimestamp;
        desc.count = 2;
        _irradianceCounterHeap = [_device newCounterHeapWithDescriptor:desc error:nil];
        _statsTicksPerSecond = [_device queryTimestampFrequency];
    }

    // Composite pipeline
    {
        MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
        vf.library = defaultLibrary;
        vf.name = @"fullscreenVertexShader";
        MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
        ff.library = defaultLibrary;
        ff.name = @"compositeFragmentShader";

        MTL4RenderPipelineDescriptor *desc = [MTL4RenderPipelineDescriptor new];
        desc.label = @"CompositePipeline";
        desc.vertexFunctionDescriptor = vf;
        desc.fragmentFunctionDescriptor = ff;
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;

        _compositePipelineState = [_compiler newRenderPipelineStateWithDescriptor:desc
                                                            compilerTaskOptions:nil
                                                                          error:&error];
        NSAssert(_compositePipelineState, @"Failed to create composite pipeline: %@", error);
    }

    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthDesc];

    for(NSUInteger i = 0; i < MaxBuffersInFlight; i++)
    {
        _dynamicUniformBuffer[i] = [_device newBufferWithLength:sizeof(Uniforms)
                                                        options:MTLResourceStorageModeShared];
        _dynamicUniformBuffer[i].label = @"UniformBuffer";
    }

    _commandQueue = [_device newMTL4CommandQueue];
    _commandBuffer = [_device newCommandBuffer];
    MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
    atd.maxBufferBindCount = 12;
    atd.maxTextureBindCount = 5;
    _argumentTable = [_device newArgumentTableWithDescriptor:atd error:&error];
    NSAssert(_argumentTable, @"Failed to create argument table: %@", error);
    MTLResidencySetDescriptor *residencySetDesc = [MTLResidencySetDescriptor new];
    _residencySet = [_device newResidencySetWithDescriptor:residencySetDesc error:&error];
    NSAssert(_residencySet, @"Failed to create residency set: %@", error);
    for(uint32_t i = 0; i < MaxBuffersInFlight; i++)
    {
        _commandAllocators[i] = [_device newCommandAllocator];
    }
    [_commandQueue addResidencySet:_residencySet];

    // Irradiance techniques.
    _techniques[IrradianceModeMonteCarlo] = [[IrradianceMonteCarloTechnique alloc] initWithDevice:_device
                                                                               compiler:_compiler
                                                                           residencySet:_residencySet];
    _techniques[IrradianceModeMPP] = [[IrradianceMPPTechnique alloc] initWithDevice:_device
                                                                  compiler:_compiler
                                                              residencySet:_residencySet];
    _techniques[IrradianceModeMLEncoder] = [[IrradianceMLEncoderTechnique alloc] initWithDevice:_device
                                                                             compiler:_compiler
                                                                         residencySet:_residencySet];

    _currentFrameIndex = MaxBuffersInFlight;
    _sharedEvent = [_device newSharedEvent];
    [_sharedEvent setSignaledValue:MaxBuffersInFlight-1];
    _statsLastTime = CFAbsoluteTimeGetCurrent();
}

- (void)createOffscreenTexturesForSize:(CGSize)size
{
    if(_normalBuffer)
        [_residencySet removeAllocation:_normalBuffer];
    if(_armBuffer)
        [_residencySet removeAllocation:_armBuffer];

    MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                        width:(NSUInteger)size.width
                                                                                       height:(NSUInteger)size.height
                                                                                    mipmapped:NO];
    colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDesc.storageMode = MTLStorageModePrivate;

    MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                        width:(NSUInteger)size.width
                                                                                       height:(NSUInteger)size.height
                                                                                    mipmapped:NO];
    depthDesc.usage = MTLTextureUsageRenderTarget;
    depthDesc.storageMode = MTLStorageModeMemoryless;

    _normalBuffer = [_device newTextureWithDescriptor:colorDesc];
    _depthBuffer = [_device newTextureWithDescriptor:depthDesc];

    MTLTextureDescriptor *armDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:(NSUInteger)size.width
                                                                                      height:(NSUInteger)size.height
                                                                                   mipmapped:NO];
    armDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    armDesc.storageMode = MTLStorageModePrivate;
    _armBuffer = [_device newTextureWithDescriptor:armDesc];

    [_residencySet addAllocation:_normalBuffer];
    [_residencySet addAllocation:_armBuffer];

    // Output tensor, shared by all techniques.
    if (_outputTensor)
        [_residencySet removeAllocation:_outputTensor];

    NSInteger dims[] = { 3, (NSInteger)size.width, (NSInteger)size.height };
    MTLTensorExtents *tensorDims = [[MTLTensorExtents alloc] initWithRank:3 values:dims];

    MTLTensorDescriptor *tensorDesc = [MTLTensorDescriptor new];
    tensorDesc.dataType = MTLTensorDataTypeFloat16;
    tensorDesc.dimensions = tensorDims;
    tensorDesc.usage = MTLTensorUsageCompute | MTLTensorUsageMachineLearning;
    tensorDesc.storageMode = MTLStorageModePrivate;

    NSError *tensorError = nil;
    _outputTensor = [_device newTensorWithDescriptor:tensorDesc error:&tensorError];
    NSAssert(_outputTensor, @"Failed to create output tensor: %@", tensorError);

    [_residencySet addAllocation:_outputTensor];
    [_residencySet commit];

    for (int i = 0; i < 3; i++)
        [_techniques[i] onResize:size];
}

- (void)loadAssets
{
    NSError *error;

    MTKTextureLoader *textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];

    NSDictionary *normalMapOptions = @{
        MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode: @(MTLStorageModePrivate),
        MTKTextureLoaderOptionSRGB: @NO
    };

    _normalMap = [textureLoader newTextureWithName:@"stone_brick_wall_001_nor_gl_2k"
                                       scaleFactor:1.0
                                            bundle:nil
                                           options:normalMapOptions
                                             error:&error];
    if(!_normalMap || error)
        NSLog(@"Error loading normal map: %@", error.localizedDescription);

    _armMap = [textureLoader newTextureWithName:@"stone_brick_wall_001_arm_2k"
                                    scaleFactor:1.0
                                         bundle:nil
                                        options:normalMapOptions
                                          error:&error];
    if(!_armMap || error)
        NSLog(@"Error loading ARM map: %@", error.localizedDescription);

    MTKMeshBufferAllocator *metalAllocator = [[MTKMeshBufferAllocator alloc] initWithDevice:_device];

    MDLMesh *mdlMesh = [MDLMesh newEllipsoidWithRadii:(vector_float3){1, 1, 1}
                                       radialSegments:32
                                     verticalSegments:16
                                         geometryType:MDLGeometryTypeTriangles
                                        inwardNormals:NO
                                           hemisphere:NO
                                            allocator:metalAllocator];

    MDLVertexDescriptor *mdlVertexDescriptor =
        MTKModelIOVertexDescriptorFromMetal(_sphereVertexDescriptor);
    mdlVertexDescriptor.attributes[VertexAttributePosition].name = MDLVertexAttributePosition;
    mdlVertexDescriptor.attributes[VertexAttributeNormal].name = MDLVertexAttributeNormal;
    mdlVertexDescriptor.attributes[VertexAttributeTexcoord].name = MDLVertexAttributeTextureCoordinate;
    mdlMesh.vertexDescriptor = mdlVertexDescriptor;

    _sphereMesh = [[MTKMesh alloc] initWithMesh:mdlMesh
                                         device:_device
                                          error:&error];
    if(!_sphereMesh || error)
        NSLog(@"Error creating sphere mesh: %@", error.localizedDescription);

    for(NSUInteger i = 0; i < MaxBuffersInFlight; i++)
        [_residencySet addAllocation:_dynamicUniformBuffer[i]];
    if(_normalMap)
        [_residencySet addAllocation:_normalMap];
    if(_armMap)
        [_residencySet addAllocation:_armMap];
    for(NSUInteger bufferIndex = 0; bufferIndex < _sphereMesh.vertexBuffers.count; bufferIndex++)
    {
        MTKMeshBuffer *vertexBuffer = _sphereMesh.vertexBuffers[bufferIndex];
        if((NSNull*)vertexBuffer != [NSNull null])
            [_residencySet addAllocation:vertexBuffer.buffer];
    }
    for(MTKSubmesh *submesh in _sphereMesh.submeshes)
        [_residencySet addAllocation:submesh.indexBuffer.buffer];

    [_residencySet commit];
}

- (void)loadEnvMap
{
    NSError *error;
    MTKTextureLoader *textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
    NSDictionary *opts = @{
        MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode: @(MTLStorageModePrivate),
        MTKTextureLoaderOptionSRGB: @NO
    };
    NSDataAsset *dataAsset = [[NSDataAsset alloc] initWithName:@"qwantani_afternoon_4k"];
    _envMap = [textureLoader newTextureWithData:dataAsset.data
                                       options:opts
                                         error:&error];
    if (!_envMap || error) {
        NSLog(@"Error loading environment map: %@", error.localizedDescription);
        return;
    }

    [_residencySet addAllocation:_envMap];
    [_residencySet commit];
    for (int i = 0; i < 3; i++)
        [_techniques[i] generateTrainingDataFromEnvMap:_envMap];
}

- (void)resetTraining
{
    [_techniques[self.irradianceMode] reset];
}

- (void)updateGameState
{
    Uniforms *uniforms = (Uniforms*)_dynamicUniformBuffer[_uniformBufferIndex].contents;

    vector_float3 xAxis = {1, 0, 0};
    vector_float3 yAxis = {0, 1, 0};
    matrix_float4x4 rotation = matrix_multiply(matrix4x4_rotation(self.cameraPitch, xAxis),
                                                matrix4x4_rotation(self.cameraYaw, yAxis));

    // Sky: rotation only
    matrix_float4x4 skyVP = matrix_multiply(_projectionMatrix, rotation);
    uniforms->inverseViewProjection = simd_inverse(skyVP);

    // Orbit camera: pull back after rotating
    matrix_float4x4 viewMatrix = matrix_multiply(matrix4x4_translation(0, 0, -self.cameraDistance),
                                                  rotation);
    uniforms->modelViewProjection = matrix_multiply(_projectionMatrix, viewMatrix);
    uniforms->exposure = 1.3f * powf(2.0f, self.exposureExponent);
}

- (void)drawGeometry
{
    MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
    rpd.colorAttachments[0].texture = _normalBuffer;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[1].texture = _armBuffer;
    rpd.colorAttachments[1].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[1].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.depthAttachment.texture = _depthBuffer;
    rpd.depthAttachment.loadAction = MTLLoadActionClear;
    rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
    rpd.depthAttachment.clearDepth = 1.0;

    id<MTL4RenderCommandEncoder> enc = [_commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setDepthStencilState:_depthState];
    [enc setRenderPipelineState:_geometryPipelineState];
    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
    [enc setCullMode:MTLCullModeBack];
    [enc setArgumentTable:_argumentTable atStages:MTLRenderStageVertex | MTLRenderStageFragment];

    [_argumentTable setAddress:_dynamicUniformBuffer[_uniformBufferIndex].gpuAddress atIndex:BufferIndexUniforms];
    [_argumentTable setTexture:_normalMap.gpuResourceID atIndex:TextureIndexNormalMap];
    [_argumentTable setTexture:_armMap.gpuResourceID atIndex:TextureIndexARMMap];

    for(NSUInteger bufferIndex = 0; bufferIndex < _sphereMesh.vertexBuffers.count; bufferIndex++)
    {
        MTKMeshBuffer *vertexBuffer = _sphereMesh.vertexBuffers[bufferIndex];
        if((NSNull*)vertexBuffer != [NSNull null])
        {
            [_argumentTable setAddress:vertexBuffer.buffer.gpuAddress + vertexBuffer.offset
                               atIndex:bufferIndex];
        }
    }

    for(MTKSubmesh *submesh in _sphereMesh.submeshes)
    {
        [enc drawIndexedPrimitives:submesh.primitiveType
                        indexCount:submesh.indexCount
                         indexType:submesh.indexType
                       indexBuffer:submesh.indexBuffer.buffer.gpuAddress + submesh.indexBuffer.offset
                 indexBufferLength:submesh.indexBuffer.buffer.length - submesh.indexBuffer.offset];
    }

    [enc barrierAfterStages:MTLStageFragment
          beforeQueueStages:MTLStageDispatch | MTLStageMachineLearning
          visibilityOptions:MTL4VisibilityOptionDevice];
    [enc endEncoding];
}

- (void)drawComposite:(nonnull MTKView *)view
{
    MTL4RenderPassDescriptor *renderPassDescriptor = view.currentMTL4RenderPassDescriptor;
    if(renderPassDescriptor == nil)
        return;

    id<MTL4RenderCommandEncoder> enc = [_commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [enc setRenderPipelineState:_compositePipelineState];
    [enc setArgumentTable:_argumentTable atStages:MTLRenderStageVertex | MTLRenderStageFragment];

    [_argumentTable setAddress:_dynamicUniformBuffer[_uniformBufferIndex].gpuAddress atIndex:BufferIndexUniforms];
    [_argumentTable setTexture:_normalBuffer.gpuResourceID atIndex:TextureIndexNormalBuffer];
    [_argumentTable setTexture:_envMap.gpuResourceID atIndex:TextureIndexEnvironment];
    [_argumentTable setTexture:_armBuffer.gpuResourceID atIndex:TextureIndexARMBuffer];
    [_argumentTable setResource:_outputTensor.gpuResourceID atBufferIndex:BufferIndexOutputTensor];

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
}

- (void)drawInMTKView:(nonnull MTKView *)view
{
    _uniformBufferIndex = _currentFrameIndex % MaxBuffersInFlight;
    [_sharedEvent waitUntilSignaledValue:_currentFrameIndex - MaxBuffersInFlight timeoutMS:UINT64_MAX];
    [_commandAllocators[_uniformBufferIndex] reset];
    [_commandBuffer beginCommandBufferWithAllocator:_commandAllocators[_uniformBufferIndex]];

    [self updateGameState];

    id<IrradianceTechnique> technique = _techniques[self.irradianceMode];
    double trainMs = [technique trainStep];

    NSData *irradianceCounterData = [_irradianceCounterHeap resolveCounterRange:NSMakeRange(0, 2)];
    const MTL4TimestampHeapEntry *entries = irradianceCounterData.bytes;
    uint64_t irradianceTimestampDiff = entries[1].timestamp > entries[0].timestamp ? (entries[1].timestamp - entries[0].timestamp) : 0;

    double irradianceTimeMs = (double)irradianceTimestampDiff / (double)_statsTicksPerSecond * 1000.0;

    _statsIrradianceTimeAccum += irradianceTimeMs;
    _statsFrameCount++;
    _statsTrainTimeAccum += trainMs;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _statsLastTime >= 0.5) {
        double avgTrainMs = _statsTrainTimeAccum / _statsFrameCount;
        double avgIrradianceMs = _statsIrradianceTimeAccum / _statsFrameCount;
        double fps = _statsFrameCount / (now - _statsLastTime);
        if (self.statsCallback) {
            self.statsCallback(fps, avgIrradianceMs, avgTrainMs, technique.totalSteps);
        }
        _statsFrameCount = 0;
        _statsTrainTimeAccum = 0;
        _statsIrradianceTimeAccum = 0;
        _statsLastTime = now;
    }

    [self drawGeometry];

    [_commandBuffer writeTimestampIntoHeap:_irradianceCounterHeap atIndex:0];
    [technique draw:_commandBuffer
        normalBuffer:_normalBuffer
        outputTensor:_outputTensor
      environmentMap:_envMap];
    [_commandBuffer writeTimestampIntoHeap:_irradianceCounterHeap atIndex:1];

    [self drawComposite:view];
    [_commandBuffer useResidencySet:((CAMetalLayer *)view.layer).residencySet];
    [_commandBuffer endCommandBuffer];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    [_commandQueue waitForDrawable:drawable];
    [_commandQueue commit:&_commandBuffer count:1];

    [_commandQueue signalEvent:_sharedEvent value:_currentFrameIndex];
    _currentFrameIndex++;

    [_commandQueue signalDrawable:drawable];
    [drawable present];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    float aspect = size.width / (float)size.height;
    _projectionMatrix = matrix_perspective_right_hand(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
    [self createOffscreenTexturesForSize:size];
}

@end
