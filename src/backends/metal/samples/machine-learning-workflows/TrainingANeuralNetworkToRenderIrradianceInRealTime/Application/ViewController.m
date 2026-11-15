/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
View controller implementation that owns the renderer, configures the Metal view, and routes user input to the camera and irradiance technique selection.
*/

#import "ViewController.h"
#import "Renderer.h"

@implementation ViewController
{
    MTKView *_view;
    Renderer *_renderer;
    NSTextField *_fpsLabel;
    NSTextField *_trainLabel;
    NSTextField *_stepsLabel;
    NSTextField *_irradianceLabel;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _view = (MTKView *)self.view;
    _view.device = MTLCreateSystemDefaultDevice();

    if(!_view.device || ![_view.device supportsFamily:MTLGPUFamilyMetal4])
    {
        NSLog(@"Metal 4 is not supported on this device");
        self.view = [[NSView alloc] initWithFrame:self.view.frame];
        return;
    }

    _renderer = [[Renderer alloc] initWithMetalKitView:_view];
    [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];
    _view.delegate = _renderer;

    [self setupUI];

    __weak typeof(self) weakSelf = self;
    _renderer.statsCallback = ^(double fps, double irradianceMs, double trainMs, uint32_t trainSteps) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_fpsLabel.stringValue = [NSString stringWithFormat:@"FPS: %.1f", fps];
        strongSelf->_irradianceLabel.stringValue = [NSString stringWithFormat:@"Irradiance: %.2f ms", irradianceMs];
        strongSelf->_trainLabel.stringValue = [NSString stringWithFormat:@"Training: %.2f ms", trainMs];
        strongSelf->_stepsLabel.stringValue = [NSString stringWithFormat:@"Training Steps: %u", trainSteps];
    };
}

- (void)setupUI
{
    NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] init];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.material = NSVisualEffectMaterialHUDWindow;
    backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    backdrop.state = NSVisualEffectStateActive;
    backdrop.wantsLayer = YES;
    backdrop.layer.cornerRadius = 8.0f;
    backdrop.layer.masksToBounds = YES;
    [_view addSubview:backdrop];

    NSTextField *modeLabel = [NSTextField labelWithString:@"Technique"];
    modeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    modeLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    modeLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:modeLabel];

    NSSegmentedControl *irradianceModeControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Monte Carlo", @"MLEncoder", @"MPP"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self
                            action:@selector(onIrradianceModeChanged:)];
    irradianceModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    irradianceModeControl.selectedSegment = 2;
    [backdrop addSubview:irradianceModeControl];

    NSButton *resetButton = [NSButton buttonWithTitle:@"Reset Weights"
                                               target:self
                                               action:@selector(onResetWeights:)];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    resetButton.bezelStyle = NSBezelStyleSmallSquare;
    [backdrop addSubview:resetButton];

    NSTextField *exposureLabel = [NSTextField labelWithString:@"Exposure"];
    exposureLabel.translatesAutoresizingMaskIntoConstraints = NO;
    exposureLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    exposureLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:exposureLabel];

    NSSlider *exposureSlider = [NSSlider sliderWithValue:0.0
                                                minValue:-1.0
                                                maxValue:1.0
                                                  target:self
                                                  action:@selector(onExposureChanged:)];
    exposureSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [backdrop addSubview:exposureSlider];

    _fpsLabel = [NSTextField labelWithString:@"FPS: --"];
    _fpsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _fpsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _fpsLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:_fpsLabel];

    _stepsLabel = [NSTextField labelWithString:@"Training Steps: 0"];
    _stepsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stepsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _stepsLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:_stepsLabel];

    _trainLabel = [NSTextField labelWithString:@"Training: -- ms"];
    _trainLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _trainLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _trainLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:_trainLabel];
    
    _irradianceLabel = [NSTextField labelWithString:@"Irradiance: -- ms"];
    _irradianceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _irradianceLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _irradianceLabel.textColor = NSColor.secondaryLabelColor;
    [backdrop addSubview:_irradianceLabel];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:_view.topAnchor constant:20],
        [backdrop.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:20],

        [modeLabel.topAnchor constraintEqualToAnchor:backdrop.topAnchor constant:12],
        [modeLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [modeLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [irradianceModeControl.topAnchor constraintEqualToAnchor:modeLabel.bottomAnchor constant:6],
        [irradianceModeControl.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [irradianceModeControl.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [resetButton.topAnchor constraintEqualToAnchor:irradianceModeControl.bottomAnchor constant:12],
        [resetButton.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [resetButton.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [exposureLabel.topAnchor constraintEqualToAnchor:resetButton.bottomAnchor constant:12],
        [exposureLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [exposureLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [exposureSlider.topAnchor constraintEqualToAnchor:exposureLabel.bottomAnchor constant:6],
        [exposureSlider.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [exposureSlider.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [_fpsLabel.topAnchor constraintEqualToAnchor:exposureSlider.bottomAnchor constant:12],
        [_fpsLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [_fpsLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [_irradianceLabel.topAnchor constraintEqualToAnchor:_fpsLabel.bottomAnchor constant:2],
        [_irradianceLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [_irradianceLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [_trainLabel.topAnchor constraintEqualToAnchor:_irradianceLabel.bottomAnchor constant:2],
        [_trainLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [_trainLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],

        [_stepsLabel.topAnchor constraintEqualToAnchor:_trainLabel.bottomAnchor constant:2],
        [_stepsLabel.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:12],
        [_stepsLabel.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:-12],
        [_stepsLabel.bottomAnchor constraintEqualToAnchor:backdrop.bottomAnchor constant:-12],
    ]];
}

- (void)onIrradianceModeChanged:(NSSegmentedControl *)sender
{
    static const IrradianceMode kSegmentToMode[] = {
        IrradianceModeMonteCarlo,
        IrradianceModeMLEncoder,
        IrradianceModeMPP,
    };
    _renderer.irradianceMode = kSegmentToMode[sender.selectedSegment];
}

- (void)onResetWeights:(NSButton *)sender
{
    [_renderer resetTraining];
}

- (void)onExposureChanged:(NSSlider *)sender
{
    _renderer.exposureExponent = sender.floatValue;
}

- (void)mouseDragged:(NSEvent *)event
{
    _renderer.cameraYaw += event.deltaX * 0.005f;
    _renderer.cameraPitch += event.deltaY * 0.005f;

    float limit = M_PI_2 - 0.01f;
    _renderer.cameraPitch = fmaxf(-limit, fminf(limit, _renderer.cameraPitch));
}

- (void)scrollWheel:(NSEvent *)event
{
    _renderer.cameraDistance -= event.deltaY * 0.1f;
    _renderer.cameraDistance = fmaxf(2.0f, fminf(20.0f, _renderer.cameraDistance));
}

@end
