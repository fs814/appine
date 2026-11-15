/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the cross-platform view controller.
*/

#if defined(TARGET_IOS) || defined(TARGET_TVOS)
@import UIKit;
#define PlatformViewController UIViewController
#else
@import AppKit;
#define PlatformViewController NSViewController
#endif

@import MetalKit;

#import "Metal4Renderer.h"

/// The app's view controller.
@interface ViewController : PlatformViewController

@end
