/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The header for the cross-platform app delegate.
*/

#if TARGET_IOS || TARGET_TVOS
#import <UIKit/UIKit.h>
#elif TARGET_MACOS
#import <Cocoa/Cocoa.h>
#endif

#if TARGET_IOS || TARGET_TVOS

@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>

#elif TARGET_MACOS

@interface AAPLAppDelegate : NSObject <NSApplicationDelegate>

@property (strong, nonatomic) NSWindow *window;

#endif

@end
