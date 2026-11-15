/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the iOS window scene delegate.
*/

#import <TargetConditionals.h>

#if TARGET_OS_IPHONE

@import UIKit;

/// The iOS window scene delegate.
@interface WindowSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;

@end

#endif
