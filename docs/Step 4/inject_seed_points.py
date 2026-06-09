#!/usr/bin/env python3
"""Seed a Brush/COLMAP dataset with the iPhone ARKit LiDAR cloud for splat initialization.

Brush initializes Gaussians from the COLMAP ``points3D`` file. Metashape exports its sparse
tie points, which are far thinner than the LiDAR ``seed_points.ply`` the phone already captured.
This rewrites ``points3D.txt`` from that cloud, expressed in the *exported reconstruction's*
coordinate frame.

We do not assume the export is in ARKit world coordinates. Instead we recover the frame
empirically: match each exported camera center to its ARKit camera center (by image label) and
solve a similarity (Umeyama, with scale). A tight residual confirms the two frames agree; the
fitted transform then maps the seed cloud into the export frame regardless of any global
scale/rotation Metashape applied.

Run in the Step 4 venv (numpy):
  python inject_seed_points.py <session_dir> <brush_dataset_dir> \
      [--mode replace|append] [--max-points N] [--max-residual M]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from arkit_colmap import quaternion_to_rotmat, read_images, read_points3D


def colmap_camera_centers(images: dict) -> dict[str, np.ndarray]:
    """Image label (no extension) -> camera center in export world coords (C = -R^T t)."""
    centers = {}
    for img in images.values():
        R = quaternion_to_rotmat(img["q"])
        center = -R.T @ img["t"]
        centers[Path(img["name"]).stem] = center
    return centers


def arkit_camera_centers(session: Path) -> dict[str, np.ndarray]:
    """Image label -> ARKit camera center (translation column of camera->world)."""
    centers = {}
    for sidecar in sorted(session.glob("shot_*.json")):
        data = json.loads(sidecar.read_text())
        T = np.asarray(data["transform_camera_to_world"], dtype=np.float64)
        centers[Path(data["image"]).stem] = T[:3, 3]
    return centers


def umeyama(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    """Least-squares similarity (scale s, rotation R, translation t) mapping src -> dst."""
    n = src.shape[0]
    mu_s, mu_d = src.mean(0), dst.mean(0)
    xs, xd = src - mu_s, dst - mu_d
    cov = xd.T @ xs / n
    U, D, Vt = np.linalg.svd(cov)
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[2, 2] = -1
    R = U @ S @ Vt
    var_s = (xs ** 2).sum() / n
    s = float((D * np.diag(S)).sum() / var_s)
    t = mu_d - s * R @ mu_s
    return s, R, t


def read_ply_xyzrgb(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Parse an ascii PLY into (xyz Nx3 float, rgb Nx3 uint8). Missing color -> gray 180."""
    with open(path) as f:
        if f.readline().strip() != "ply":
            raise SystemExit(f"{path} is not an ascii PLY")
        props: list[str] = []
        count = 0
        for line in f:
            s = line.strip()
            if s.startswith("element vertex"):
                count = int(s.split()[-1])
            elif s.startswith("property"):
                props.append(s.split()[-1])
            elif s == "end_header":
                break
        data = np.loadtxt(f, max_rows=count)
    if data.ndim == 1:
        data = data.reshape(1, -1)
    idx = {name: i for i, name in enumerate(props)}
    xyz = data[:, [idx["x"], idx["y"], idx["z"]]].astype(np.float64)
    if {"red", "green", "blue"} <= idx.keys():
        rgb = data[:, [idx["red"], idx["green"], idx["blue"]]].astype(np.uint8)
    else:
        rgb = np.full((xyz.shape[0], 3), 180, dtype=np.uint8)
    return xyz, rgb


def write_points3D(path: Path, xyz: np.ndarray, rgb: np.ndarray, start_id: int, existing: str) -> None:
    lines = [existing.rstrip("\n")] if existing else [
        "# 3D point list with one line of data per point:",
        "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)",
    ]
    for i, (p, c) in enumerate(zip(xyz, rgb)):
        pid = start_id + i
        # Empty track: Brush initializes splat position/color from XYZ+RGB; tracks are unused.
        lines.append(f"{pid} {p[0]:.6f} {p[1]:.6f} {p[2]:.6f} {int(c[0])} {int(c[1])} {int(c[2])} 1.0")
    path.write_text("\n".join(lines) + "\n")


def run(args: argparse.Namespace) -> None:
    session = args.session.expanduser().resolve()
    sparse = args.dataset.expanduser().resolve() / "sparse" / "0"
    images_txt = sparse / "images.txt"
    points_txt = sparse / "points3D.txt"
    if not images_txt.exists():
        raise SystemExit(f"missing {images_txt}; run the Metashape export first")

    ply_name = "seed_points.ply"
    manifest = session / "manifest.json"
    if manifest.exists():
        ply_name = json.loads(manifest.read_text()).get("seed_point_cloud") or ply_name
    ply_path = session / ply_name
    if not ply_path.exists():
        raise SystemExit(f"no seed cloud at {ply_path}")

    export_c = colmap_camera_centers(read_images(images_txt))
    arkit_c = arkit_camera_centers(session)
    shared = sorted(set(export_c) & set(arkit_c))
    if len(shared) < 3:
        raise SystemExit(f"only {len(shared)} matched cameras; need >=3 to fit a frame")

    src = np.array([arkit_c[k] for k in shared])
    dst = np.array([export_c[k] for k in shared])
    s, R, t = umeyama(src, dst)
    resid = np.linalg.norm((s * (src @ R.T) + t) - dst, axis=1)
    rms = float(np.sqrt((resid ** 2).mean()))
    print(f"matched cameras: {len(shared)}")
    print(f"ARKit->export similarity: scale={s:.5f} rms_residual={rms:.4f} m max={resid.max():.4f} m")
    if rms > args.max_residual:
        raise SystemExit(
            f"residual {rms:.4f} m exceeds --max-residual {args.max_residual} m; "
            "frames disagree — refusing to inject a misaligned cloud"
        )

    xyz, rgb = read_ply_xyzrgb(ply_path)
    if args.max_points and xyz.shape[0] > args.max_points:
        sel = np.linspace(0, xyz.shape[0] - 1, args.max_points).astype(int)
        xyz, rgb = xyz[sel], rgb[sel]
        print(f"subsampled seed cloud to {xyz.shape[0]} points")
    xyz_export = (s * (xyz @ R.T) + t)

    existing = ""
    start_id = 1
    if args.mode == "append" and points_txt.exists():
        existing = points_txt.read_text()
        ids = [int(l.split()[0]) for l in existing.splitlines() if l and not l.startswith("#")]
        start_id = (max(ids) + 1) if ids else 1
        kept = len(ids)
    else:
        kept = 0

    write_points3D(points_txt, xyz_export, rgb, start_id, existing)
    total = kept + xyz_export.shape[0]
    print(f"mode={args.mode}: wrote {xyz_export.shape[0]} seed points (kept {kept}) -> {points_txt} (total {total})")
    print("DONE")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", type=Path, help="spatialcam session dir (has seed_points.ply)")
    parser.add_argument("dataset", type=Path, help="Brush dataset dir (has sparse/0/)")
    parser.add_argument("--mode", choices=["replace", "append"], default="replace",
                        help="replace tie points with the seed cloud, or append to them")
    parser.add_argument("--max-points", type=int, default=0, help="optional cap (0 = keep all)")
    parser.add_argument("--max-residual", type=float, default=0.10,
                        help="abort if camera-center fit RMS (m) exceeds this")
    return parser.parse_args()


if __name__ == "__main__":
    run(parse_args())
