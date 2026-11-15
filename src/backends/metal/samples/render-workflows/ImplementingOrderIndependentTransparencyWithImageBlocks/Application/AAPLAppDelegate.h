/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The application delegate's header.
*/

#import <TargetConditionals.h>

#if TARGET_OS_IPHONE

@import UIKit;

@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>

@end

#else

#import <Cocoa/Cocoa.h>
@import AppKit;

@interface AAPLAppDelegate : NSObject<NSApplicationDelegate>

@end

#endif

