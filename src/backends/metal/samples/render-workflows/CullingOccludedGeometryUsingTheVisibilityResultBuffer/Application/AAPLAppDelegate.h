/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The header for the cross-platform application delegate.
*/

#if defined(TARGET_MACOS)

@import AppKit;
#define PlatformAppDelegate NSObject <NSApplicationDelegate>
#define PlatformWindow      NSWindow
#define PlatformApplication NSApplication

#elif defined(TARGET_IOS) || defined (TARGET_TVOS)

@import UIKit;
#define PlatformAppDelegate UIResponder <UIApplicationDelegate>
#define PlatformWindow      UIWindow
#define PlatformApplication UIApplication

#endif

@interface AAPLAppDelegate : PlatformAppDelegate

#if defined(TARGET_MACOS)
@property (strong, nonatomic) PlatformWindow *window;
#endif

@end
