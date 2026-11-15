/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Trainer implementation that generates ground-truth normal/irradiance pairs via Monte Carlo, dispatches training iterations using cooperative matmul kernels, and updates weights with Adam.
*/

#import "IrradianceTrainer.h"

#define kTrainIterations 20
#define kMaxTrainSteps 5000

@implementation IrradianceTrainer
{
    id<MTLDevice> _device;
    id<MTLResidencySet> _residencySet;
    IrradianceModel *_model;

    id<MTLBuffer> _masterWeightBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _adamMBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _adamVBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _gradBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _masterBiasBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _adamMBiasBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _adamVBiasBuffers[MLP_NUM_LAYERS];
    id<MTLBuffer> _gradBiasBuffers[MLP_NUM_LAYERS];

    id<MTLBuffer> _trainDataBuffer;
    id<MTLBuffer> _trainDimsBuffer;
    id<MTLBuffer> _batchSizeBuffer;
    id<MTLBuffer> _adamParamsBuffer;

    id<MTLComputePipelineState> _generateSamplesPipelineState;
    id<MTLComputePipelineState> _mlpTrainStepPipelineState;
    id<MTLComputePipelineState> _adamUpdateWeightsPipelineState;
    id<MTLComputePipelineState> _adamUpdateBiasPipelineState;
    id<MTLComputePipelineState> _kaimingInitPipelineState;

    id<MTL4CommandQueue> _commandQueue;
    id<MTL4CommandAllocator> _commandAllocator;
    id<MTL4CommandBuffer> _commandBuffer;
    id<MTLSharedEvent> _event;
    uint64_t _eventValue;

    id<MTL4ArgumentTable> _trainStepArgumentTable;
    id<MTL4ArgumentTable> _generateSamplesArgTable;
    id<MTL4ArgumentTable> _adamWeightArgTables[kTrainIterations][MLP_NUM_LAYERS];
    id<MTL4ArgumentTable> _adamBiasArgTables[kTrainIterations][MLP_NUM_LAYERS];
}

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                                 model:(nonnull IrradianceModel *)model
                          residencySet:(nonnull id<MTLResidencySet>)residencySet
{
    self = [super init];
    if (!self) return self;

    _device = device;
    _residencySet = residencySet;
    _model = model;

    [self createPipelines:compiler];
    [self createTrainingBuffersAndTables];
    [residencySet commit];

    return self;
}

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

- (void)createPipelines:(id<MTL4Compiler>)compiler
{
    id<MTLLibrary> lib = [_device newDefaultLibrary];

    _generateSamplesPipelineState   = newComputePipeline(compiler, lib, @"generateSamplesKernel");
    _mlpTrainStepPipelineState      = newComputePipeline(compiler, lib, @"mlpTrainStepKernel");
    _adamUpdateWeightsPipelineState = newComputePipeline(compiler, lib, @"adamUpdateWeightsKernel");
    _adamUpdateBiasPipelineState    = newComputePipeline(compiler, lib, @"adamUpdateBiasKernel");
    _kaimingInitPipelineState       = newComputePipeline(compiler, lib, @"kaimingInitKernel");
}

- (void)createTrainingBuffersAndTables
{
    NSError *error;

    _trainDataBuffer = [_device newBufferWithLength:TRAINING_BATCH_SIZE * 6 * sizeof(uint16_t)
                                            options:MTLResourceStorageModeShared];

    _commandQueue = [_device newMTL4CommandQueue];
    _commandAllocator = [_device newCommandAllocator];
    _commandBuffer = [_device newCommandBuffer];
    _event = [_device newSharedEvent];
    _eventValue = 0;

    MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
    atd.maxBufferBindCount = 20;
    _trainStepArgumentTable = [_device newArgumentTableWithDescriptor:atd error:&error];
    NSAssert(_trainStepArgumentTable, @"Failed to create train step argument table: %@", error);

    _trainDimsBuffer = [_device newBufferWithLength:sizeof(TrainingLayerDims)
                                            options:MTLResourceStorageModeShared];

    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        uint32_t n = _model->layers[i].rows, k = _model->layers[i].cols;
        size_t floatBytes = n * k * sizeof(float);
        size_t biasFloatBytes = n * sizeof(float);

        _gradBuffers[i] = [_device newBufferWithLength:floatBytes options:MTLResourceStorageModeShared];
        _adamMBuffers[i] = [_device newBufferWithLength:floatBytes options:MTLResourceStorageModeShared];
        _adamVBuffers[i] = [_device newBufferWithLength:floatBytes options:MTLResourceStorageModeShared];
        memset(_gradBuffers[i].contents, 0, floatBytes);
        memset(_adamMBuffers[i].contents, 0, floatBytes);
        memset(_adamVBuffers[i].contents, 0, floatBytes);

        _masterWeightBuffers[i] = [_device newBufferWithLength:floatBytes options:MTLResourceStorageModeShared];

        _masterBiasBuffers[i] = [_device newBufferWithLength:biasFloatBytes options:MTLResourceStorageModeShared];
        _adamMBiasBuffers[i]  = [_device newBufferWithLength:biasFloatBytes options:MTLResourceStorageModeShared];
        _adamVBiasBuffers[i]  = [_device newBufferWithLength:biasFloatBytes options:MTLResourceStorageModeShared];
        _gradBiasBuffers[i]   = [_device newBufferWithLength:biasFloatBytes options:MTLResourceStorageModeShared];
        memset(_masterBiasBuffers[i].contents, 0, biasFloatBytes);
        memset(_adamMBiasBuffers[i].contents,  0, biasFloatBytes);
        memset(_adamVBiasBuffers[i].contents,  0, biasFloatBytes);
        memset(_gradBiasBuffers[i].contents,   0, biasFloatBytes);
    }

    // Sample generation argument table
    _batchSizeBuffer = [_device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
    *(uint32_t *)_batchSizeBuffer.contents = TRAINING_BATCH_SIZE;

    MTL4ArgumentTableDescriptor *genATD = [MTL4ArgumentTableDescriptor new];
    genATD.maxBufferBindCount  = 2;
    genATD.maxTextureBindCount = 1;
    _generateSamplesArgTable = [_device newArgumentTableWithDescriptor:genATD error:&error];
    NSAssert(_generateSamplesArgTable, @"Failed to create sample gen argument table: %@", error);
    [_generateSamplesArgTable setAddress:_trainDataBuffer.gpuAddress atIndex:0];
    [_generateSamplesArgTable setAddress:_batchSizeBuffer.gpuAddress atIndex:1];

    // Adam update argument tables (inference weight bindings set per-call)
    _adamParamsBuffer = [_device newBufferWithLength:
                             kTrainIterations * MLP_NUM_LAYERS * 2 * sizeof(AdamUpdateParams)
                                            options:MTLResourceStorageModeShared];

    MTL4ArgumentTableDescriptor *adamATD = [MTL4ArgumentTableDescriptor new];
    adamATD.maxBufferBindCount = 6;

    for (int iter = 0; iter < kTrainIterations; iter++) {
        for (int l = 0; l < MLP_NUM_LAYERS; l++) {
            _adamWeightArgTables[iter][l] = [_device newArgumentTableWithDescriptor:adamATD error:&error];
            NSAssert(_adamWeightArgTables[iter][l], @"Adam weight table [%d][%d]: %@", iter, l, error);
            [_adamWeightArgTables[iter][l] setAddress:_gradBuffers[l].gpuAddress        atIndex:0];
            [_adamWeightArgTables[iter][l] setAddress:_masterWeightBuffers[l].gpuAddress atIndex:1];
            [_adamWeightArgTables[iter][l] setAddress:_adamMBuffers[l].gpuAddress        atIndex:2];
            [_adamWeightArgTables[iter][l] setAddress:_adamVBuffers[l].gpuAddress        atIndex:3];
            [_adamWeightArgTables[iter][l] setResource:_model->layers[l].weights.gpuResourceID atBufferIndex:4];

            int wIdx = (iter * MLP_NUM_LAYERS + l) * 2 + 0;
            [_adamWeightArgTables[iter][l] setAddress:_adamParamsBuffer.gpuAddress + wIdx * sizeof(AdamUpdateParams)
                                              atIndex:5];

            _adamBiasArgTables[iter][l] = [_device newArgumentTableWithDescriptor:adamATD error:&error];
            NSAssert(_adamBiasArgTables[iter][l], @"Adam bias table [%d][%d]: %@", iter, l, error);
            [_adamBiasArgTables[iter][l] setAddress:_gradBiasBuffers[l].gpuAddress       atIndex:0];
            [_adamBiasArgTables[iter][l] setAddress:_masterBiasBuffers[l].gpuAddress     atIndex:1];
            [_adamBiasArgTables[iter][l] setAddress:_adamMBiasBuffers[l].gpuAddress      atIndex:2];
            [_adamBiasArgTables[iter][l] setAddress:_adamVBiasBuffers[l].gpuAddress      atIndex:3];
            [_adamBiasArgTables[iter][l] setAddress:_model->layers[l].biases.gpuAddress  atIndex:4];

            int bIdx = (iter * MLP_NUM_LAYERS + l) * 2 + 1;
            [_adamBiasArgTables[iter][l] setAddress:_adamParamsBuffer.gpuAddress + bIdx * sizeof(AdamUpdateParams)
                                            atIndex:5];
        }
    }

    // Add training buffers to residency set
    [_residencySet addAllocation:_trainDataBuffer];
    [_residencySet addAllocation:_trainDimsBuffer];
    [_residencySet addAllocation:_batchSizeBuffer];
    [_residencySet addAllocation:_adamParamsBuffer];
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        [_residencySet addAllocation:_gradBuffers[i]];
        [_residencySet addAllocation:_gradBiasBuffers[i]];
        [_residencySet addAllocation:_masterWeightBuffers[i]];
        [_residencySet addAllocation:_masterBiasBuffers[i]];
        [_residencySet addAllocation:_adamMBuffers[i]];
        [_residencySet addAllocation:_adamVBuffers[i]];
        [_residencySet addAllocation:_adamMBiasBuffers[i]];
        [_residencySet addAllocation:_adamVBiasBuffers[i]];
    }

    // Train step argument table - static bindings (resources never change)
    for (int l = 0; l < MLP_NUM_LAYERS; l++) {
        [_trainStepArgumentTable setResource:_model->layers[l].weights.gpuResourceID
                               atBufferIndex:BufferIndexMLPLayer0 + l];
        [_trainStepArgumentTable setAddress:_model->layers[l].biases.gpuAddress
                                    atIndex:BufferIndexMLPBias0 + l];
        [_trainStepArgumentTable setAddress:_gradBuffers[l].gpuAddress
                                    atIndex:BufferIndexMLPGradLayer0 + l];
        [_trainStepArgumentTable setAddress:_gradBiasBuffers[l].gpuAddress
                                    atIndex:BufferIndexMLPGradBias0 + l];
    }
    [_trainStepArgumentTable setAddress:_trainDataBuffer.gpuAddress atIndex:BufferIndexMLPTrainData];
    [_trainStepArgumentTable setAddress:_trainDimsBuffer.gpuAddress atIndex:BufferIndexMLPDims];
}

- (void)dispatchKaimingInit
{
    id<MTLBuffer> paramsBuffer = [_device newBufferWithLength:MLP_NUM_LAYERS * sizeof(KaimingInitParams)
                                                     options:MTLResourceStorageModeShared];
    KaimingInitParams *paramsPtr = (KaimingInitParams *)paramsBuffer.contents;
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        uint32_t k = _model->layers[i].cols, n = _model->layers[i].rows;
        paramsPtr[i] = (KaimingInitParams){ .cols = k, .rows = n, .fanIn = (i == 0) ? 3 : k, .seed = arc4random() };
    }

    [_commandAllocator reset];
    [_commandBuffer beginCommandBufferWithAllocator:_commandAllocator];
    [_commandBuffer useResidencySet:_residencySet];

    id<MTL4ComputeCommandEncoder> enc = [_commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_kaimingInitPipelineState];

    MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
    atd.maxBufferBindCount = 3;

    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        NSError *error;
        id<MTL4ArgumentTable> argTable = [_device newArgumentTableWithDescriptor:atd error:&error];
        [argTable setAddress:_masterWeightBuffers[i].gpuAddress atIndex:0];
        [argTable setResource:_model->layers[i].weights.gpuResourceID atBufferIndex:1];
        [argTable setAddress:paramsBuffer.gpuAddress + i * sizeof(KaimingInitParams) atIndex:2];

        [enc setArgumentTable:argTable];
        [enc dispatchThreads:MTLSizeMake(_model->layers[i].cols, _model->layers[i].rows, 1)
            threadsPerThreadgroup:MTLSizeMake(16, 2, 1)];
    }

    [enc endEncoding];
    [_commandBuffer endCommandBuffer];
    _eventValue++;
    [_commandQueue commit:&_commandBuffer count:1];
    [_commandQueue signalEvent:_event value:_eventValue];
    [_event waitUntilSignaledValue:_eventValue timeoutMS:UINT64_MAX];
}

- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap
{
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        memset(_adamMBuffers[i].contents,     0, _adamMBuffers[i].length);
        memset(_adamVBuffers[i].contents,     0, _adamVBuffers[i].length);
        memset(_adamMBiasBuffers[i].contents, 0, _adamMBiasBuffers[i].length);
        memset(_adamVBiasBuffers[i].contents, 0, _adamVBiasBuffers[i].length);
    }
    _totalSteps = 0;

    [_generateSamplesArgTable setTexture:envMap.gpuResourceID atIndex:0];

    [_commandAllocator reset];
    [_commandBuffer beginCommandBufferWithAllocator:_commandAllocator];
    [_commandBuffer useResidencySet:_residencySet];

    id<MTL4ComputeCommandEncoder> enc = [_commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_generateSamplesPipelineState];
    [enc setArgumentTable:_generateSamplesArgTable];
    [enc dispatchThreads:MTLSizeMake(TRAINING_BATCH_SIZE, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [enc endEncoding];

    [_commandBuffer endCommandBuffer];
    _eventValue++;
    [_commandQueue commit:&_commandBuffer count:1];
    [_commandQueue signalEvent:_event value:_eventValue];
}

- (double)trainStep
{
    if (_totalSteps >= kMaxTrainSteps)
        return 0;

    static const float beta1 = 0.9f, beta2 = 0.999f, eps = 1e-8f, lr = 0.0005f;

    AdamUpdateParams *paramPtr = (AdamUpdateParams *)_adamParamsBuffer.contents;
    for (int iter = 0; iter < kTrainIterations; iter++) {
        uint32_t step = _totalSteps + iter + 1;
        for (int l = 0; l < MLP_NUM_LAYERS; l++) {
            int wIdx = (iter * MLP_NUM_LAYERS + l) * 2 + 0;
            int bIdx = (iter * MLP_NUM_LAYERS + l) * 2 + 1;
            paramPtr[wIdx] = (AdamUpdateParams){
                .rows=_model->layers[l].rows, .cols=_model->layers[l].cols,
                .adamStep=step, .beta1=beta1, .beta2=beta2, .eps=eps, .lr=lr };
            paramPtr[bIdx] = (AdamUpdateParams){
                .rows=_model->layers[l].rows, .cols=1,
                .adamStep=step, .beta1=beta1, .beta2=beta2, .eps=eps, .lr=lr };
        }
    }

    TrainingLayerDims dims = { .N2 = 3, .batchSize = TRAINING_BATCH_SIZE };
    memcpy(_trainDimsBuffer.contents, &dims, sizeof(dims));

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    [_commandAllocator reset];
    [_commandBuffer beginCommandBufferWithAllocator:_commandAllocator];
    [_commandBuffer useResidencySet:_residencySet];

    id<MTL4ComputeCommandEncoder> enc = [_commandBuffer computeCommandEncoder];

    for (int iter = 0; iter < kTrainIterations; iter++) {
        for (int l = 0; l < MLP_NUM_LAYERS; l++) {
            [enc fillBuffer:_gradBuffers[l] range:NSMakeRange(0, _gradBuffers[l].length) value:0];
            [enc fillBuffer:_gradBiasBuffers[l] range:NSMakeRange(0, _gradBiasBuffers[l].length) value:0];
        }
        [enc barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageDispatch
              visibilityOptions:MTL4VisibilityOptionDevice];

        [enc setComputePipelineState:_mlpTrainStepPipelineState];
        [enc setArgumentTable:_trainStepArgumentTable];
        [enc dispatchThreads:MTLSizeMake(TRAINING_BATCH_SIZE, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        [enc barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageDispatch
              visibilityOptions:MTL4VisibilityOptionDevice];

        for (int l = 0; l < MLP_NUM_LAYERS; l++) {
            [enc setComputePipelineState:_adamUpdateWeightsPipelineState];
            [enc setArgumentTable:_adamWeightArgTables[iter][l]];
            [enc dispatchThreads:MTLSizeMake(_model->layers[l].cols, _model->layers[l].rows, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 2, 1)];

            [enc setComputePipelineState:_adamUpdateBiasPipelineState];
            [enc setArgumentTable:_adamBiasArgTables[iter][l]];
            [enc dispatchThreads:MTLSizeMake(_model->layers[l].rows, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        }
        [enc barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageDispatch
              visibilityOptions:MTL4VisibilityOptionDevice];
    }

    [enc endEncoding];

    [_commandBuffer endCommandBuffer];
    _eventValue++;
    [_commandQueue commit:&_commandBuffer count:1];
    [_commandQueue signalEvent:_event value:_eventValue];
    [_event waitUntilSignaledValue:_eventValue timeoutMS:UINT64_MAX];

    _totalSteps += kTrainIterations;
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
}

- (void)reset
{
    _totalSteps = 0;
    for (uint32_t i = 0; i < MLP_NUM_LAYERS; i++) {
        uint32_t n = _model->layers[i].rows, k = _model->layers[i].cols;
        size_t floatBytes = n * k * sizeof(float);
        size_t biasFloatBytes = n * sizeof(float);

        memset(_gradBuffers[i].contents, 0, floatBytes);
        memset(_adamMBuffers[i].contents, 0, floatBytes);
        memset(_adamVBuffers[i].contents, 0, floatBytes);
        memset(_gradBiasBuffers[i].contents, 0, biasFloatBytes);
        memset(_adamMBiasBuffers[i].contents, 0, biasFloatBytes);
        memset(_adamVBiasBuffers[i].contents, 0, biasFloatBytes);
        memset(_masterBiasBuffers[i].contents, 0, biasFloatBytes);
        memset(_model->layers[i].biases.contents, 0, n * sizeof(__fp16));
    }
    [self dispatchKaimingInit];
}

@end
