# Machine learning pass backend

`M-x appine-metal-mlpass` opens a tab that multiplies two matrices with a
Metal 4 machine learning pass and checks the product against the CPU. The code
is Apple's sample
[Running a machine learning model on the GPU timeline](https://developer.apple.com/documentation/metal/running-a-machine-learning-model-on-the-gpu-timeline),
copied into this directory. Its license is in
`LICENSE-RunningAMachineLearningModelOnTheGPUTimeline.txt`.

The sample is a command-line tool. `../../backend_metal_mlpass.m` does what its
`main.m` does and shows what it would print: both input matrices, the CPU and
GPU products, whether they match, and timings. The tab can rerun with new
random matrices of any size up to 512.

Needs Metal 4 (`MTLGPUFamilyMetal4`: Apple silicon on macOS 26 or later);
otherwise the tab says so.

## Files

- `Matrix*`, `MLMatrixMultiplier*`: the sample's code, flattened from its
  `Matrix/` and `Matrix multiplier/` folders.
- `Packages/matrix-multiplication.mtlpackage`: the model as a Metal package,
  which is what runs.
- `matrix-multiplication.mlpackage`: the Core ML model it was built from, kept
  for reference. Rebuild the Metal package with
  `xcrun metal-package-builder -ml matrix-multiplication.mlpackage -o Packages/matrix-multiplication.mtlpackage`.

## Changes from the sample

- **Class names prefixed** `AppineMLMatrix`, `AppineMLMatrixMultiplier`.
  Objective-C class names are global in the Emacs process, and `Matrix` is
  generic. File names are unchanged.
- **Package location**: the sample loads the `.mtlpackage` from its app
  bundle; here `appine_mlpass_package_url` finds it in the appine checkout.

Not copied: `main.m` (its steps are in the backend) and the Xcode project.
