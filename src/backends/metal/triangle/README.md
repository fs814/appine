# Metal triangle backend

`M-x appine-metal-triangle` opens an appine tab with a Metal view that draws a
colorful, rotating triangle. The renderer code is Apple's sample
[Drawing a triangle with Metal 4](https://developer.apple.com/documentation/metal/drawing-a-triangle-with-metal-4)
(WWDC25 session 205), copied into this directory. Its license is in
`LICENSE-DrawingATriangleWithMetal4.txt`.

The sample's `MetalKitViewDelegate` picks the Metal 4 renderer when the GPU is
in `MTLGPUFamilyMetal4` (Apple silicon on macOS 26 or later) and the classic
Metal renderer otherwise. `../../backend_metal_triangle.m` hosts it in an
appine tab.

## Changes from the sample

Only what running inside Emacs instead of the sample's own app requires:

- **Shaders compiled at runtime.** The sample loads `default.metallib` from its
  app bundle with `newDefaultLibrary`. Emacs has no such library, so the
  Makefile embeds `ShaderTypes.h` + `Shaders.metal` (both unchanged) in the
  dylib, and `AppineTriangleShaders.m` compiles them through `../common/`.
  Building appine therefore needs no Metal toolchain.
- **No `NSAssert`.** A failed assert would throw into Emacs, so
  `APPINE_METAL_ASSERT` (`../common/`, imported by `RendererProtocol.h`) logs
  instead. The backend compiles the shaders before creating a renderer and
  shows a message in the tab when Metal or the shaders are unavailable.
- **`#import <MetalKit/MetalKit.h>`** instead of `@import MetalKit;`, because
  appine builds without Clang modules.
- **Metal 4 guard.** The `#if !TARGET_OS_SIMULATOR` guards became
  `#if __has_include(<Metal/MTL4CommandQueue.h>)`, so an SDK older than macOS
  26 still builds, with the classic renderer only.

Not copied: the app shell (`Application/`, `View controller/ViewController.*`,
`UI/` storyboards, Info.plists, Xcode project) and
`Shaders/Descriptors.mtl4-json`, an Xcode build input for an offline pipeline
archive. The renderer's `configureCompilerTaskOptions` looks for that archive
in the main bundle, finds none, and compiles the pipeline at runtime.
