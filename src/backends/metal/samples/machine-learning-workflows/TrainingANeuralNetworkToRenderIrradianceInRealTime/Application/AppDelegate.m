/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
App delegate implementation that terminates the app when the last window closes.
*/

#import "AppDelegate.h"

@implementation AppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
