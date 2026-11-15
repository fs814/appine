/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Trainer interface that runs GPU-resident forward and backward passes to fit the irradiance MLP.
*/

#import <MetalKit/MetalKit.h>
#import "IrradianceModel.h"

@interface IrradianceTrainer : NSObject

@property (nonatomic, readonly) uint32_t totalSteps;

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                              compiler:(nonnull id<MTL4Compiler>)compiler
                                 model:(nonnull IrradianceModel *)model
                          residencySet:(nonnull id<MTLResidencySet>)residencySet;

- (void)generateTrainingDataFromEnvMap:(nonnull id<MTLTexture>)envMap;
- (double)trainStep;
- (void)reset;

@end
