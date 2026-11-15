/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Header for the cross-platform view controller
*/

@import MetalKit;
#import "AAPLRenderer.h"

#if defined(TARGET_IOS) || defined(TARGET_TVOS)

@import UIKit;

// Our view controller
@interface AAPLViewController : UIViewController

@end

#else

@import AppKit;

// Our view controller
@interface AAPLViewController : NSViewController

@end

#endif


