/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Definition of the per-layer MLP parameters held in Metal tensors, including weights, biases, and Adam optimizer state.
*/

#import <Metal/Metal.h>
#import "ShaderTypes.h"

typedef struct {
    id<MTLTensor> __strong weights;
    id<MTLBuffer> __strong biases;
    uint32_t rows;
    uint32_t cols;
} IrradianceModelLayer;

typedef struct {
    IrradianceModelLayer layers[MLP_NUM_LAYERS];
} IrradianceModel;
