# Combining blit and compute operations in a single pass

Run concurrent blit commands and then a compute dispatch in a single pass with a unified compute encoder.

This sample demonstrates how to use Metal 4's unified compute encoder to combine texture data and create a grayscale version of it at the same time.
The app runs blit and dispatch operations in a single compute pass, then renders the results with a render pass.

This sample builds on Metal 4 fundamentals in <doc:drawing-a-triangle-with-metal-4>,
including command buffers, allocators, residency sets, and submitting work to the GPU.

Each time the system requests a frame, the app:
1. Creates a composite color texture by copying two color textures with concurrent blit commands.
2. Creates a grayscale texture by converting the composite color texture with a compute kernel.
3. Draws two adjacent rectangles, one for each composite texture.

An `MTL4ComputeCommandEncoder` instance combines blit, dispatch, and acceleration structure commands into a single pass,
which reduces your app's overhead from creating multiple encoders and encoding separate passes.
The app increases its GPU utilization by running independent blit commands that concurrently write to memory regions that don't overlap.
However, it prevents the blit and dispatch stage memory operations from running at the same time, by synchronizing them with an intrapass barrier.

For more information about the sample, see
[Combining blit and compute operations in a single pass](https://developer.apple.com/documentation/metal/combining-blit-and-compute-operations-in-a-single-pass).
