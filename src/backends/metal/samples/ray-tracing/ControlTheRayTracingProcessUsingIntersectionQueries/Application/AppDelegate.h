/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Header for the cross-platform app delegate.
*/

#import <TargetConditionals.h>

#if !TARGET_OS_IPHONE
#import <Cocoa/Cocoa.h>
#define PlatformAppDelegate NSObject <NSApplicationDelegate>
#define PlatformWindow NSWindow
#else
#import <UIKit/UIKit.h>
#define PlatformAppDelegate UIResponder <UIApplicationDelegate>
#define PlatformWindow UIWindow
#endif

@interface AppDelegate : PlatformAppDelegate

#if !TARGET_OS_IPHONE
@property (strong, nonatomic) PlatformWindow *window;
#endif

@end
