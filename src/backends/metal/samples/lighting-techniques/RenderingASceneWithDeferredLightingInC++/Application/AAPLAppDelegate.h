/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Header for the iOS & tvOS application delegate
*/

#if defined(TARGET_IOS) || defined(TARGET_TVOS)

#import <UIKit/UIKit.h>

@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>

@end

#else

#import <AppKit/AppKit.h>

@interface AAPLAppDelegate : NSObject<NSApplicationDelegate>

@end

#endif
