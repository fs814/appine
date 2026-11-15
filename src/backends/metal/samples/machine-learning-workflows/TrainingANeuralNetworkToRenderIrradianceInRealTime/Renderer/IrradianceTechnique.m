/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Concrete implementations of the Monte Carlo, MPP MLP, and Core ML irradiance techniques, each building their own pipelines and encoding their own per-frame dispatches.
*/

#import "IrradianceTechnique.h"
#import "IrradianceTrainer.h"
#import "IrradianceModel.h"

static id<MTLComputePipelineState> newComputePipeline(id<MTL4Compiler> compiler,
                                                      id<MTLLibrary> library,
                                                      NSString *functionName)
{
    MTL4LibraryFunctionDescriptor *functionDescriptor = [MTL4LibraryFunctionDescriptor new];
    functionDescriptor.library = library;
    functionDescriptor.name = functionName;
    MTL4ComputePipelineDescriptor *pipelineDescriptor = [MTL4ComputePipelineDescriptor new];
    pipelineDescriptor.computeFunctionDescriptor = functionDescriptor;
    NSError *error;
    id<MTLComputePipelineState> pipelineState = [compiler newComputePipelineStateWithDescriptor:pipelineDescriptor
                                                                           compilerTaskOptions:nil
                                                                                         error:&error];
    NSCAssert(pipelineState, @"%@: %@", functionName, error);
    return pipelineState;
}

static id<MTL4ArgumentTable> newArgumentTable(id<MTLDevice> device,
                                               NSUInteger maxBuffers,
                                               NSUInteger maxTextures)
{
    MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
    descriptor.maxBufferBindCount = maxBuffers;
    descriptor.maxTextureBindCount = maxTextures;
    NSError *error;
    id<MTL4ArgumentTable> argumentTable = [device newArgumentTableWithDescriptor:descriptor error:&error];
    NSCAssert(argumentTable, @"Failed to create argument table: %@", error);
    return argumentTable;
}

@implementation IrradianceMonteCarloTechnique
{
    id<MTLComputePipelineState> _pipelineState;
    id<MTL4ArgumentTable> _argumentTable;
}

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet
{
    self = [super init];
    if (self) {
        id<MTLLibrary> library = [device newDefaultLibrary];
        _pipelineState = newComputePipeline(compiler, library, @"irradianceMCComputeShader");
        _argumentTable = newArgumentTable(device, 6, 5);
    }
    return self;
}

- (void)draw:(nonnull id<MTL4CommandBuffer>)commandBuffer
normalBuffer:(nonnull id<MTLTexture>)normalBuffer
outputTensor:(nonnull id<MTLTensor>)outputTensor
environmentMap:(nonnull id<MTLTexture>)envMap
{
    id<MTL4ComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_pipelineState];
    [enc setArgumentTable:_argumentTable];

    [_argumentTable setTexture:normalBuffer.gpuResourceID atIndex:TextureIndexNormalBuffer];
    [_argumentTable setResource:outputTensor.gpuResourceID atBufferIndex:BufferIndexOutputTensor];
    [_argumentTable setTexture:envMap.gpuResourceID atIndex:TextureIndexEnvironment];

    MTLSize gridSize = MTLSizeMake(normalBuffer.width, normalBuffer.height, 1);
    [enc dispatchThreads:gridSize threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc barrierAfterStages:MTLStageDispatch
          beforeQueueStages:MTLStageFragment
          visibilityOptions:MTL4VisibilityOptionDevice];
    [enc endEncoding];
}

- (void)onResize:(CGSize)size {}
- (double)trainStep { return 0; }
- (void)reset {}
- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap {}
- (uint32_t)totalSteps { return 0; }

@end

@implementation IrradianceMPPTechnique
{
    id<MTLComputePipelineState> _pipelineState;
    id<MTL4ArgumentTable> _argumentTable;
    IrradianceModel _model;
    IrradianceTrainer *_trainer;
    id<MTLResidencySet> _residencySet;
}

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet
{
    self = [super init];
    if (self) {
        _residencySet = residencySet;
        NSError *error;
        id<MTLLibrary> library = [device newDefaultLibrary];

        _pipelineState = newComputePipeline(compiler, library, @"irradianceMLPComputeShader");
        _argumentTable = newArgumentTable(device, 12, 5);

        // MLP model buffers.
        static const uint32_t mlpK[MLP_NUM_LAYERS] = {16, 16, 16};
        static const uint32_t mlpN[MLP_NUM_LAYERS] = {16, 16, 8};

        for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
            uint32_t K = mlpK[i], N = mlpN[i];
            _model.layers[i].rows = N;
            _model.layers[i].cols = K;

            _model.layers[i].biases = [device newBufferWithLength:N * sizeof(uint16_t)
                                                          options:MTLResourceStorageModeShared];
            memset(_model.layers[i].biases.contents, 0, N * sizeof(uint16_t));
            [residencySet addAllocation:_model.layers[i].biases];

            NSInteger dimValues[2] = {(NSInteger)K, (NSInteger)N};
            MTLTensorDescriptor *tensorDesc = [MTLTensorDescriptor new];
            tensorDesc.dataType = MTLTensorDataTypeFloat16;
            tensorDesc.dimensions = [[MTLTensorExtents alloc] initWithRank:2 values:dimValues];
            tensorDesc.usage = MTLTensorUsageCompute;

            _model.layers[i].weights = [device newTensorWithDescriptor:tensorDesc error:&error];
            NSAssert(_model.layers[i].weights, @"Failed to create MLP layer %u tensor: %@", i, error);
            [residencySet addAllocation:_model.layers[i].weights];
        }
        [residencySet commit];

        _trainer = [[IrradianceTrainer alloc] initWithDevice:device
                                                       compiler:compiler
                                                          model:&_model
                                                   residencySet:residencySet];
        [_trainer reset];
    }
    return self;
}

- (void)draw:(nonnull id<MTL4CommandBuffer>)commandBuffer
normalBuffer:(nonnull id<MTLTexture>)normalBuffer
outputTensor:(nonnull id<MTLTensor>)outputTensor
environmentMap:(nonnull id<MTLTexture>)envMap
{
    id<MTL4ComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_pipelineState];
    [enc setArgumentTable:_argumentTable];

    [_argumentTable setTexture:normalBuffer.gpuResourceID atIndex:TextureIndexNormalBuffer];
    [_argumentTable setResource:outputTensor.gpuResourceID atBufferIndex:BufferIndexOutputTensor];
    [_argumentTable setTexture:envMap.gpuResourceID atIndex:TextureIndexEnvironment];
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++)
        [_argumentTable setResource:_model.layers[i].weights.gpuResourceID
                        atBufferIndex:BufferIndexMLPLayer0 + i];
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++)
        [_argumentTable setAddress:_model.layers[i].biases.gpuAddress
                           atIndex:BufferIndexMLPBias0 + i];

    MTLSize gridSize = MTLSizeMake(normalBuffer.width, normalBuffer.height, 1);
    [enc dispatchThreads:gridSize threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc barrierAfterStages:MTLStageDispatch
          beforeQueueStages:MTLStageFragment
          visibilityOptions:MTL4VisibilityOptionDevice];
    [enc endEncoding];
}

- (void)onResize:(CGSize)size {}

- (double)trainStep {
    return [_trainer trainStep];
}

- (void)reset {
    [_trainer reset];
}

- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap {
    [_trainer generateTrainingDataFromEnvMap:envMap];
}

- (uint32_t)totalSteps {
    return _trainer.totalSteps;
}

@end

@implementation IrradianceMLEncoderTechnique
{
    id<MTL4Compiler> _compiler;
    id<MTLDevice> _device;
    id<MTLResidencySet> _residencySet;

    id<MTLComputePipelineState> _normalToTensorPipelineState;
    id<MTL4MachineLearningPipelineState> _mlPipelineState;
    id<MTLTensor> _mlInputTensor;
    id<MTLHeap> _mlIntermediatesHeap;
    id<MTL4ArgumentTable> _mlArgumentTable;
    id<MTL4ArgumentTable> _normalToTensorArgumentTable;
    id<MTLLibrary> _mlLibrary;
}

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet
{
    self = [super init];
    if (self) {
        _device = device;
        _compiler = compiler;
        _residencySet = residencySet;

        id<MTLLibrary> library = [device newDefaultLibrary];
        _normalToTensorPipelineState = newComputePipeline(compiler, library, @"textureToTensorKernel");
        _normalToTensorArgumentTable = newArgumentTable(device, 5, 5);

        // Load .mtlpackage.
        NSError *error;
        NSURL *packageURL = [[NSBundle mainBundle] URLForResource:@"Irradiance" withExtension:@"mtlpackage"];
        NSAssert(packageURL, @"Irradiance.mtlpackage not found in bundle");
        _mlLibrary = [device newLibraryWithURL:packageURL error:&error];
        NSAssert(_mlLibrary, @"Failed to load ML library: %@", error);

        _mlArgumentTable = newArgumentTable(device, 2, 0);
    }
    return self;
}

- (void)onResize:(CGSize)size
{
    if (_mlInputTensor)
        [_residencySet removeAllocation:_mlInputTensor];
    if (_mlIntermediatesHeap)
        [_residencySet removeAllocation:_mlIntermediatesHeap];

    NSInteger dims[] = { 3, (NSInteger)size.width, (NSInteger)size.height };
    MTLTensorExtents *tensorDims = [[MTLTensorExtents alloc] initWithRank:3 values:dims];

    MTLTensorDescriptor *tensorDesc = [MTLTensorDescriptor new];
    tensorDesc.dataType = MTLTensorDataTypeFloat16;
    tensorDesc.dimensions = tensorDims;
    tensorDesc.usage = MTLTensorUsageCompute | MTLTensorUsageMachineLearning;
    tensorDesc.storageMode = MTLStorageModePrivate;

    NSError *error;
    _mlInputTensor = [_device newTensorWithDescriptor:tensorDesc error:&error];
    NSAssert(_mlInputTensor, @"Failed to create ML input tensor: %@", error);

    MTL4LibraryFunctionDescriptor *mlFD = [MTL4LibraryFunctionDescriptor new];
    mlFD.library = _mlLibrary;
    mlFD.name = @"main";

    MTL4MachineLearningPipelineDescriptor *mlDesc = [MTL4MachineLearningPipelineDescriptor new];
    mlDesc.label = @"IrradianceMLEncoderPipeline";
    mlDesc.machineLearningFunctionDescriptor = mlFD;
    [mlDesc setInputDimensions:tensorDims atBufferIndex:0];

    _mlPipelineState = [_compiler newMachineLearningPipelineStateWithDescriptor:mlDesc
                                                                          error:&error];
    NSAssert(_mlPipelineState, @"Failed to create ML irradiance pipeline: %@", error);

    MTLHeapDescriptor *heapDesc = [MTLHeapDescriptor new];
    heapDesc.type = MTLHeapTypePlacement;
    heapDesc.size = MAX(_mlPipelineState.intermediatesHeapSize, 1);
    _mlIntermediatesHeap = [_device newHeapWithDescriptor:heapDesc];

    [_residencySet addAllocation:_mlInputTensor];
    [_residencySet addAllocation:_mlIntermediatesHeap];
    [_residencySet commit];

    [_mlArgumentTable setResource:_mlInputTensor.gpuResourceID atBufferIndex:0];
}

- (void)draw:(nonnull id<MTL4CommandBuffer>)commandBuffer
normalBuffer:(nonnull id<MTLTexture>)normalBuffer
outputTensor:(nonnull id<MTLTensor>)outputTensor
environmentMap:(nonnull id<MTLTexture>)envMap
{
    // Convert normal texture to tensor.
    id<MTL4ComputeCommandEncoder> computeEnc = [commandBuffer computeCommandEncoder];
    [computeEnc setComputePipelineState:_normalToTensorPipelineState];
    [computeEnc setArgumentTable:_normalToTensorArgumentTable];

    [_normalToTensorArgumentTable setTexture:normalBuffer.gpuResourceID atIndex:TextureIndexNormalBuffer];
    [_normalToTensorArgumentTable setResource:_mlInputTensor.gpuResourceID atBufferIndex:BufferIndexNormalTensor];

    MTLSize gridSize = MTLSizeMake(normalBuffer.width, normalBuffer.height, 1);
    [computeEnc dispatchThreads:gridSize threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [computeEnc barrierAfterStages:MTLStageDispatch
          beforeQueueStages:MTLStageMachineLearning
          visibilityOptions:MTL4VisibilityOptionDevice];
    [computeEnc endEncoding];

    // Dispatch ML network.
    [_mlArgumentTable setResource:outputTensor.gpuResourceID atBufferIndex:1];

    id<MTL4MachineLearningCommandEncoder> mlEnc = [commandBuffer machineLearningCommandEncoder];
    [mlEnc setPipelineState:_mlPipelineState];
    [mlEnc setArgumentTable:_mlArgumentTable];

    [mlEnc dispatchNetworkWithIntermediatesHeap:_mlIntermediatesHeap];
    [mlEnc barrierAfterStages:MTLStageMachineLearning
          beforeQueueStages:MTLStageFragment
          visibilityOptions:MTL4VisibilityOptionDevice];
    [mlEnc endEncoding];
}

- (double)trainStep { return 0; }
- (void)reset {}
- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap {}
- (uint32_t)totalSteps { return 0; }

@end
