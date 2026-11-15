/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Application delegate for Metal Sample Code
*/

#if TARGET_IOS || TARGET_TVOS
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

#if TARGET_IOS || TARGET_TVOS
@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>
#else
@interface AAPLAppDelegate : NSObject <NSApplicationDelegate>
#endif

@end
