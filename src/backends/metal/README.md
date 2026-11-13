# Metal sample demos

Two of Apple's Metal samples, running in appine tabs inside Emacs:

| Command | Directory | Sample |
|---|---|---|
| `M-x appine-metal-triangle` | `triangle/` | [Drawing a triangle with Metal 4](https://developer.apple.com/documentation/metal/drawing-a-triangle-with-metal-4) |
| `M-x appine-metal-raytracing` | `raytracing/` | [Accelerating ray tracing using Metal](https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal) |

Each directory holds that sample's renderer code, its license, and a README
listing what changed. The hosts are `../backend_metal_triangle.m` and
`../backend_metal_raytracing.mm`. Both open through one native function,
`appine-native-open-metal-in-rect`. The demo is named by the tab path
(`appine:metal-triangle`, `appine:metal-raytracing`), which is also what the
session saves.

## common/

What both samples need in order to run inside Emacs instead of in their own
apps (`AppineMetalCommon.h`):

- `appine_metal_library_from_source`: both samples load their shaders with
  `newDefaultLibrary`, which reads `default.metallib` from the app bundle.
  Emacs has none, so the Makefile embeds each sample's `ShaderTypes.h` +
  `Shaders.metal` in the dylib (one generic rule,
  `build/appine_<demo>_shaders.inc`), and this compiles them at first use,
  cached per device. Building appine needs no Metal toolchain.
- `APPINE_METAL_ASSERT`: the samples' `NSAssert`s would throw into Emacs; this
  logs instead. The backends check the device and compile the shaders before
  creating a renderer, and show a message in the tab
  (`appine_metal_message_view`) when this Mac cannot run the demo.

## Why the samples stay apart

The two samples clash, so they are kept in separate directories:

- Both have a `ShaderTypes.h` and a `Shaders.metal`, with different contents.
  The sample directories are not on the compiler's include path. Their files
  include siblings with quotes, which resolve next to the including file.
- The ray tracer's Objective-C classes had generic names (`Renderer`, `Scene`,
  `Geometry`, ...), which are global in the Emacs process. They are prefixed
  `AppineRT`. The triangle's `Renderer` is a protocol, so it does not collide.
- The ray tracer is Objective-C++. The Makefile compiles each file with flags
  for its language and links with `clang++`.
