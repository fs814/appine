# Apple's Metal sample code library

All 49 samples of Apple's
[Metal sample code library](https://developer.apple.com/documentation/metal/metal-sample-code-library),
arranged as on that page, running in appine tabs.

- `M-x appine-metal-sample`: pick a sample, grouped by the page's categories,
  each with its state and summary.
- `M-x appine-metal-samples`: the library as a browsable list. `RET` runs a
  sample, `d` opens its page on developer.apple.com, `g` refreshes.

## Layout

| Path | What |
|---|---|
| `<category>/<Sample>/` | The sample as Apple ships it, one folder per category of the web page (`render-workflows/`, `ray-tracing/`, ...). Files over 2 MB are not in git. |
| `catalog.json` | Categories and samples in the page's order: titles, summaries, page and zip links. |
| `large-files.tsv` | The 76 files over 2 MB (about 2.1 GB of textures, scenes and models), with checksums. |
| `tools/import_samples.py` | Re-imports the library from Apple's downloads (writes everything above). |
| `tools/fetch_samples.py` | Restores the large files from Apple's zips, cached in `~/Library/Caches/appine/metal-samples/`. |
| `tools/build_sample.py`, `tools/build_all.py` | Build samples into `build/metal-samples/<Sample>.bundle`; `status.json` records the outcome. |
| `tools/patches/` | The few local fixes a sample needs to run inside Emacs; each says why at its top. |
| `../../backend_metal_samples.m` | The tab: loads a bundle and shows the sample's app or command-line output. |

## Building

```sh
make metal-samples                      # all of them; fetches large files first
make metal-samples SAMPLES="ModernRenderingWithMetal HDR..."   # some
```

Needs Xcode (clang, swiftc, ibtool, actool) and its Metal toolchain.

## How a sample runs inside Emacs

The sample's own Xcode project is the source of truth: `build_sample.py` reads
its macOS target with `plutil` (sources, resources, frameworks, build settings,
per-file flags, Xcode 16 synchronised folders, shell-script phases,
Metal-library targets it depends on) and builds a loadable bundle instead of
an app: code, `default.metallib`, compiled storyboard and asset catalog, and
the sample's other resources (hard links, not copies).

The tab then shows what the sample's app would show: its macOS storyboard's
initial view controller, with the `MTKView` and any controls. A command-line
sample's `main()` runs with its output shown, and a button runs it again.

Three things would otherwise break when 46 apps share one process with Emacs:

- **Class names.** Objective-C class names are global, and most samples define
  the same ones (`AAPLRenderer` is in 29). Each sample's classes are renamed
  per sample by a generated prefix header, and its storyboard is compiled from
  a copy whose `customClass` attributes match. Swift samples instead get a
  unique module name. Keyed archives that name the original classes are
  mapped back when the sample opens.
- **The main bundle.** `[NSBundle mainBundle]` and `newDefaultLibrary` would
  look in Emacs.app. In Objective-C they are rewritten by the same prefix
  header. For metal-cpp and Swift, which reach them through the Objective-C
  runtime, the host answers them with the sample's bundle when, and only when,
  the caller's code is inside a sample bundle. `MTKTextureLoader` lookups with
  `bundle:nil` go to the most recently opened sample.
- **Bugs that never show in a sample's own app**, because the app exits before
  they matter. See `tools/patches/`.

## State

| | Samples |
|---|---|
| Built and verified rendering (or printing) in a tab | 46 |
| No app to run: Python workflows that extend TensorFlow and PyTorch, and Hydra, which needs Pixar's USD built from source | 3 (`appine-metal-sample` opens their README) |

Samples that need hardware features a Mac lacks report so in the tab.
Frames are drawn by each sample's own `MTKView`, on Emacs's main thread.
