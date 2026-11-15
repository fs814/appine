#!/usr/bin/env python3
"""
Train an MLP to approximate diffuse irradiance from an HDR environment map.

Training data is generated via cosine-weighted Monte Carlo hemisphere
integration (matching the approach in Irradiance.metal). The trained
network maps a unit surface normal to an RGB irradiance value.

Export produces:
  Irradiance.mlpackage  - Core ML model (via coremltools)
  Irradiance.mtlpackage - Metal package (via metal-package-builder)
"""

import argparse
import subprocess
from pathlib import Path

import coremltools as ct
import cv2
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

_ASSETS        = Path(__file__).parent / "Model"
HDR_PATH       = Path(__file__).parent / "Renderer" / "Assets.xcassets/qwantani_afternoon_4k.dataset/qwantani_afternoon_4k.hdr"
OUT_MLPACKAGE  = _ASSETS / "Irradiance.mlpackage"
OUT_MTLPACKAGE = _ASSETS / "Irradiance.mtlpackage"

NUM_TRAIN  = 20_000
NUM_VAL    =  2_000
GI_SAMPLES =    512
EPOCHS     =  2_000
BATCH_SIZE =    512
LR         =  1e-3
EVAL_EVERY =    200


def load_hdr(path: Path) -> np.ndarray:
    """Load an HDR image as a float32 (H, W, 3) array."""
    img = cv2.imread(str(path), cv2.IMREAD_UNCHANGED | cv2.IMREAD_ANYDEPTH)
    if img is None:
        raise FileNotFoundError(f"Could not load HDR: {path}")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32)


def _dirs_to_uv(d: np.ndarray) -> np.ndarray:
    """Convert unit directions (..., 3) to equirectangular UV (..., 2)."""
    phi   = np.arctan2(d[..., 2], d[..., 0])
    theta = np.arcsin(np.clip(d[..., 1], -1.0, 1.0))
    u = phi / (2.0 * np.pi) + 0.5
    v = -theta / np.pi + 0.5
    return np.stack([u, v], axis=-1)


def _sample_env(env: np.ndarray, dirs: np.ndarray) -> np.ndarray:
    """Bilinear-sample the env map (H, W, 3) at unit directions (..., 3)."""
    H, W, _ = env.shape
    uv = _dirs_to_uv(dirs)
    px = uv[..., 0] * W - 0.5
    py = uv[..., 1] * H - 0.5

    x0 = np.floor(px).astype(np.int32) % W
    x1 = (x0 + 1) % W
    y0 = np.clip(np.floor(py).astype(np.int32), 0, H - 1)
    y1 = np.clip(y0 + 1,                         0, H - 1)

    wx = (px - np.floor(px))[..., np.newaxis]
    wy = (py - np.floor(py))[..., np.newaxis]

    return (env[y0, x0] * (1 - wx) * (1 - wy) +
            env[y1, x0] * (1 - wx) *      wy  +
            env[y0, x1] *      wx  * (1 - wy) +
            env[y1, x1] *      wx  *      wy)


def _cosine_sample_hemisphere(xi: np.ndarray) -> np.ndarray:
    """Map (N, 2) uniform samples to (N, 3) cosine-weighted directions (z-up)."""
    cos_t = np.sqrt(1.0 - xi[:, 1])
    sin_t = np.sqrt(       xi[:, 1])
    phi   = 2.0 * np.pi * xi[:, 0]
    return np.stack([sin_t * np.cos(phi), sin_t * np.sin(phi), cos_t], axis=1)


def _uniform_sphere(N: int, rng: np.random.Generator) -> np.ndarray:
    """Generate N uniformly distributed unit directions on the sphere."""
    z   = rng.uniform(-1.0, 1.0, N)
    phi = rng.uniform(0.0, 2.0 * np.pi, N)
    r   = np.sqrt(np.maximum(1.0 - z * z, 0.0))
    return np.stack([r * np.cos(phi), r * np.sin(phi), z], axis=1).astype(np.float32)


def _compute_irradiance(normals: np.ndarray, env: np.ndarray,
                        num_samples: int = 512) -> np.ndarray:
    """Cosine-weighted Monte Carlo irradiance, matching the Metal shader."""
    rng       = np.random.default_rng(0)
    xi        = rng.random((num_samples, 2))
    local_dir = _cosine_sample_hemisphere(xi).astype(np.float32)
    out       = np.zeros((len(normals), 3), dtype=np.float32)
    chunk     = 1024

    for start in range(0, len(normals), chunk):
        end = min(start + chunk, len(normals))
        ns  = normals[start:end]

        up = np.where(np.abs(ns[:, 1:2]) < 0.999,
                      np.broadcast_to([0.0, 1.0, 0.0], ns.shape).copy(),
                      np.broadcast_to([1.0, 0.0, 0.0], ns.shape).copy())
        T = np.cross(up, ns)
        T /= np.linalg.norm(T, axis=1, keepdims=True)
        B = np.cross(ns, T)

        world = (local_dir[np.newaxis, :, 0:1] * T [:, np.newaxis, :] +
                 local_dir[np.newaxis, :, 1:2] * B [:, np.newaxis, :] +
                 local_dir[np.newaxis, :, 2:3] * ns[:, np.newaxis, :])

        colors = np.minimum(_sample_env(env, world.reshape(-1, 3)), 10.0)
        out[start:end] = (colors.reshape(end - start, num_samples, 3)
                                .sum(axis=1) * (np.pi / num_samples))

        print(f"\r  computing irradiance ... {100 * end / len(normals):5.1f}%", end="", flush=True)

    print()
    return out


class IrradianceMLP(nn.Module):

    def __init__(self, layer_sizes: list[int]):
        super().__init__()
        assert layer_sizes[0] == 3 and layer_sizes[-1] == 3
        self.layer_sizes = layer_sizes
        self.linears = nn.ModuleList([
            nn.Linear(layer_sizes[i], layer_sizes[i + 1])
            for i in range(len(layer_sizes) - 1)
        ])
        self.act = nn.LeakyReLU(0.01)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for linear in self.linears[:-1]:
            x = self.act(linear(x))
        return self.linears[-1](x)


class _DecodedMLP(nn.Module):
    """Wraps IrradianceMLP with exp(x)-1 decode for export."""

    def __init__(self, mlp: IrradianceMLP):
        super().__init__()
        self.mlp = mlp

    def forward(self, normal: torch.Tensor) -> torch.Tensor:
        return torch.clamp(torch.exp(self.mlp(normal)) - 1.0, min=0.0)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Train an irradiance MLP from an HDR environment map.",
    )
    parser.add_argument(
        "--layers", type=int, nargs="+", default=[3, 16, 16, 3], metavar="N",
        help="Layer sizes (default: 3 16 16 3). First and last must be 3.",
    )
    parser.add_argument(
        "--patience", type=int, default=3, metavar="N",
        help="Early-stopping patience in evaluation rounds (default: 3, 0 to disable).",
    )
    args = parser.parse_args()

    print("Loading environment map ...")
    env = load_hdr(HDR_PATH)
    print(f"  shape={env.shape}  max={env.max():.2f}")

    rng     = np.random.default_rng(42)
    normals = _uniform_sphere(NUM_TRAIN + NUM_VAL, rng)

    print(f"Computing irradiance ({GI_SAMPLES} MC samples per normal) ...")
    irradiance = _compute_irradiance(normals, env, num_samples=GI_SAMPLES)

    targets = np.log1p(irradiance)
    print(f"  irradiance range [{irradiance.min():.4f}, {irradiance.max():.4f}]")

    X_tr = torch.tensor(normals[:NUM_TRAIN])
    Y_tr = torch.tensor(targets[:NUM_TRAIN])
    X_va = torch.tensor(normals[NUM_TRAIN:])
    Y_va = torch.tensor(targets[NUM_TRAIN:])

    loader  = DataLoader(TensorDataset(X_tr, Y_tr), batch_size=BATCH_SIZE, shuffle=True)
    model   = IrradianceMLP(args.layers)
    opt     = torch.optim.Adam(model.parameters(), lr=LR)
    loss_fn = nn.MSELoss()

    arch = "-".join(str(s) for s in args.layers)
    params = sum(p.numel() for p in model.parameters())
    print(f"\narch={arch}  params={params}")
    print(f"Training up to {EPOCHS} epochs, batch={BATCH_SIZE}, lr={LR}\n")

    best_val = float("inf")
    wait     = 0

    for epoch in range(1, EPOCHS + 1):
        model.train()
        running = 0.0
        for xb, yb in loader:
            pred = model(xb)
            loss = loss_fn(pred, yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            running += loss.item() * len(xb)

        if epoch % EVAL_EVERY != 0 and epoch != 1:
            continue

        model.eval()
        with torch.no_grad():
            val_loss = loss_fn(model(X_va), Y_va).item()
        print(f"  epoch {epoch:5d}/{EPOCHS}  "
              f"train={running / NUM_TRAIN:.6f}  val={val_loss:.6f}")

        if args.patience:
            if val_loss < best_val - 1e-5:
                best_val = val_loss
                wait     = 0
            else:
                wait += 1
                if wait >= args.patience:
                    print(f"  Early stopping (best val={best_val:.6f})")
                    break

    print("\nExporting ...")
    model.eval()
    wrapped = _DecodedMLP(model).eval()
    traced  = torch.jit.trace(wrapped, torch.zeros(1, 1, 3))

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(
            name="normal",
            shape=(ct.RangeDim(1, 4096), ct.RangeDim(1, 4096), 3),
        )],
        outputs=[ct.TensorType(name="irradiance")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.save(OUT_MLPACKAGE)
    print(f"Wrote {OUT_MLPACKAGE}")

    # Convert to Metal package.
    subprocess.run(
        ["xcrun", "-sdk", "macosx", "metal-package-builder",
         str(OUT_MLPACKAGE), "-o", str(OUT_MTLPACKAGE), "-ml"],
        check=True,
    )
    print(f"Wrote {OUT_MTLPACKAGE}")
    print("Done.")


if __name__ == "__main__":
    main()
