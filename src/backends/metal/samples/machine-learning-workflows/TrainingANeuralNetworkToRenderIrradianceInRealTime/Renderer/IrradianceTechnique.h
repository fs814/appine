/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Protocol that the three irradiance techniques conform to, providing a common interface for setup and per-frame encoding.
*/

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "ShaderTypes.h"

@protocol IrradianceTechnique <NSObject>

- (void)draw:(nonnull id<MTL4CommandBuffer>)commandBuffer
normalBuffer:(nonnull id<MTLTexture>)normalBuffer
outputTensor:(nonnull id<MTLTensor>)outputTensor
environmentMap:(nonnull id<MTLTexture>)envMap;

- (void)onResize:(CGSize)size;
- (double)trainStep;
- (void)reset;
- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap;

@property (nonatomic, readonly) uint32_t totalSteps;

@end

// An implementation of global illumination using a brute force monte carlo integration.
@interface IrradianceMonteCarloTechnique : NSObject <IrradianceTechnique>

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet;

@end

// An implementation of global illumination using a MLP network implemented using Metal Performance Primitives.
//
// Training is done live (see IrradianceTrainer) over multiple frames.
@interface IrradianceMPPTechnique : NSObject <IrradianceTechnique>

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet;

@end

// An implementation of global illumination using a MLP network trained offline in PyTorch and launched with an MTL4MachineLearningCommandEncoder.
//
// An additional compute pass is run before to convert the normals from the geometry pass to a tensor in the expected format.
@interface IrradianceMLEncoderTechnique : NSObject <IrradianceTechnique>

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                          residencySet:(nonnull id<MTLResidencySet>)residencySet;

@end
