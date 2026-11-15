/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A class that multiplies matrices with a Metal machine learning pipeline.
*/

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "Matrix.h"

NS_ASSUME_NONNULL_BEGIN

/// A class that manages Metal objects and multiplies matrices using Metal's
/// machine learning features.
///
/// Create a matrix multiplier, configure it with ``configureWithMatrix1:matrix2:``,
/// and run the computation with ``encodeAndRunModelInference``.
/// Retrieve the product tensor with the ``productTensor`` method.
/// appine: where the model's Metal package is. The sample looks in its app
/// bundle; inside Emacs it is in the appine checkout (backend_metal_mlpass.m).
NSURL *_Nullable appine_mlpass_package_url(NSString *name);

@interface AppineMLMatrixMultiplier : NSObject

/// Creates a matrix multiplier.
- (instancetype)init;

/// Prepares the multiplier to run a matrix multiplication in a machine learning
/// pass on a Metal device.
/// - Parameters:
///   - matrix1: A matrix for the first input.
///   - matrix2: A matrix for the second input.
/// - Returns: A Boolean value that indicates whether the method succeeds.
- (BOOL)configureWithMatrix1:(AppineMLMatrix *)matrix1
                     matrix2:(AppineMLMatrix *)matrix2;

/// Encodes a machine learning pass and runs it on the GPU.
- (void)encodeAndRunModelInference;

/// Returns the product tensor from the GPU computation.
- (id<MTLTensor>)productTensor;

@end

NS_ASSUME_NONNULL_END
