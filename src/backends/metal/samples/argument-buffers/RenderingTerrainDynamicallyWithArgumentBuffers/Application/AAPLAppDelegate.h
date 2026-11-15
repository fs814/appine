/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Declaration of the Application Delegate object
*/

#pragma once

#import "TargetConditionals.h"

#if TARGET_OS_IOS

#import <UIKit/UIKit.h>

@interface AAPLAppDelegate : UIResponder <UIApplicationDelegate>

@end

#else

#import <Cocoa/Cocoa.h>

@interface AAPLAppDelegate : NSObject <NSApplicationDelegate>

@end

#endif
