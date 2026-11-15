/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The interface for the iOS and tvOS window scene delegate.
*/

#import <TargetConditionals.h>

#if TARGET_OS_IOS

#import <UIKit/UIKit.h>

/// The iOS and tvOS window scene delegate.
@interface WindowSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;

@end

#endif
