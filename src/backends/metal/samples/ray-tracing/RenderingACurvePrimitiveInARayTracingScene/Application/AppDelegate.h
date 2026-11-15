/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The header for the cross-platform app delegate.
*/

#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define PlatformAppDelegate UIResponder <UIApplicationDelegate>
#define PlatformWindow UIWindow
#elif TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#define PlatformAppDelegate NSObject <NSApplicationDelegate>
#define PlatformWindow NSWindow
#endif

@interface AppDelegate : PlatformAppDelegate

@end
