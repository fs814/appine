/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Renderer interface that exposes camera controls and the irradiance technique selector for switching between Monte Carlo integration, an on-device trained MLP, and a pretrained Core ML model.
*/

#import <MetalKit/MetalKit.h>

typedef NS_ENUM(NSInteger, IrradianceMode)
{
    IrradianceModeMonteCarlo = 0,
    IrradianceModeMPP        = 1,
    IrradianceModeMLEncoder  = 2,
};

@interface Renderer : NSObject <MTKViewDelegate>

@property (nonatomic) float cameraYaw;
@property (nonatomic) float cameraPitch;
@property (nonatomic) float cameraDistance;
@property (nonatomic) float exposureExponent;
@property (nonatomic) IrradianceMode irradianceMode;
@property (nonatomic, copy, nullable) void (^statsCallback)(double fps, double irradianceMs, double trainMs, uint32_t trainSteps);

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
-(void)resetTraining;

@end
