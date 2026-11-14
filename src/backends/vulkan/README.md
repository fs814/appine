# Khronos Vulkan-Samples

`M-x appine-vulkan-sample` runs a sample from
[KhronosGroup/Vulkan-Samples](https://github.com/KhronosGroup/Vulkan-Samples)
in an appine tab. Vulkan runs on Metal through MoltenVK, from the LunarG
Vulkan SDK.

## Layout

| Path | What |
|---|---|
| `Vulkan-Samples/` | Upstream's code, copied unmodified at the commit in `UPSTREAM_COMMIT`: framework, all samples, shaders, CMake build. Apache-2.0 (`Vulkan-Samples/LICENSE`). |
| `Vulkan-Samples/third_party/*/`, `Vulkan-Samples/assets/` | Not in git. About 525 MB of libraries and 1 GB of scenes and textures, downloaded by `fetch_deps.sh` at the commits upstream pins (`deps.tsv`). |
| `appine/` | The appine side: a platform for the samples' framework (`appine_vulkan_samples.cpp`, modelled on upstream's iOS platform), its C interface, and `appine.cmake`, which adds the library to upstream's build without editing it. |
| `../backend_vulkan_samples.m` | The tab: a `CAMetalLayer` view, one frame per display tick, mouse input. |

## Building

The samples are a separate library, `appine-vulkan-samples.dylib`, because the
project is large (about 1300 build steps). The main appine module builds and
runs without it, and loads it on first use.

```sh
Settings/binmac/init/vulkan-init.sh        # Vulkan SDK, once
src/backends/vulkan/fetch_deps.sh          # libraries and assets, once
make vulkan-samples EMACS_INCLUDE_DIR=...  # needs cmake (and ninja if present)
```

## Limits

- One sample at a time: the framework keeps global state. A second tab says so.
- A sample that needs something MoltenVK lacks (hardware ray tracing queries
  it does not expose, some extensions, OpenGL or OpenCL interop) fails to
  start, and the tab shows the framework's error.
- Frames are drawn on Emacs's main thread, so a heavy sample makes Emacs less
  responsive while its tab is visible.
- Left mouse button and drag are forwarded; keyboard is not.
- The library finds MoltenVK through the Vulkan SDK it was built against
  (`VK_ICD_FILENAMES`, unless already set), so that SDK must stay installed.

## Updating to a newer upstream

Copy upstream's tree over `Vulkan-Samples/` (without `.git`, the third-party
folders' contents and `assets/`), update `UPSTREAM_COMMIT` and `deps.tsv` from
its `.gitmodules` and `git submodule status`, then re-run `fetch_deps.sh`.
