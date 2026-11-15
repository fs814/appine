/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Header for the application delegate
*/
#if defined(TARGET_IOS)

@import UIKit;

@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>

@end

#else

@import AppKit;

@interface AAPLAppDelegate : NSObject<NSApplicationDelegate>

@end

#endif
