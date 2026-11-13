# Ray tracing backend

`M-x appine-metal-raytracing` opens an appine tab that path traces an
instanced Cornell box with spheres. The renderer code is Apple's sample
[Accelerating ray tracing using Metal](https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal)
(WWDC20 10012, WWDC22 10105), copied into this directory. Its license is in
`LICENSE-AcceleratingRayTracingUsingMetal.txt`. The image starts noisy and
converges as frames accumulate. Resizing the Emacs window restarts it.

`../../backend_metal_raytracing.mm` hosts it. As the sample's view controller
does, it picks a GPU that supports ray tracing, preferring one that is not
low power. It also requires Metal 3, which the sample is built for; otherwise
the tab says why it cannot run.

## Changes from the sample

Only what running inside Emacs instead of the sample's own app requires:

- **Shaders compiled at runtime** (`AppineRayTracingShaders.m`, via
  `../common/`), with `SUPPORTS_METAL_3=1` and Metal language 3.0 as in the
  sample's Xcode project. The Objective-C++ side gets `SUPPORTS_METAL_3=1`
  from the Makefile. `ShaderTypes.h` and `Shaders.metal` are unchanged.
- **Class names prefixed `AppineRT`** (`AppineRTRenderer`, `AppineRTScene`,
  `AppineRTGeometry`, `AppineRTTriangleGeometry`, `AppineRTSphereGeometry`,
  `AppineRTGeometryInstance`). Objective-C class names are global in the
  Emacs process, and these were generic. File names are unchanged.
- **`NSAssert` became `APPINE_METAL_ASSERT`** (logs instead of throwing into
  Emacs).
- **Zero size**: an appine view starts at zero size before Emacs places it.
  `mtkView:drawableSizeWillChange:` ignores a zero size, and `drawInMTKView:`
  draws nothing until the accumulation targets exist.

Not copied: the app shell (`Application/`, storyboards, Info.plists, asset
catalog, Xcode project). The renderer's managed-storage calls are deprecated
in the macOS 27 SDK; they are kept because Intel GPUs need them, and that
warning is silenced for these files.
