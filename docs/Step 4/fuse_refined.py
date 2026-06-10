#!/usr/bin/env python3
"""
fuse_refined.py — build a Brush dataset from BA-refined poses + LiDAR depth fusion.

Takes the output of run_colmap.sh (which triangulates + bundle-adjusts against the
ARKit poses) and replaces the tie-point cloud with LiDAR depth unprojected through
the REFINED poses/intrinsics — dense init everywhere LiDAR saw surface, not just
where SIFT found texture. This was the "run 4" configuration in
REVIEW_2026-06-09_53-53Z.md (best free registration + dense seeds).

Usage:
  python3 fuse_refined.py SESSION_DIR BA_OUT_DIR [--stride 2] [--voxel 0.015]
                          [--max-depth 8.0]

  SESSION_DIR  the capture session (shot_*.json + depth raws)
  BA_OUT_DIR   output dir of run_colmap.sh; must contain brush_dataset/sparse/0
               (TXT model with refined poses)

Writes BA_OUT_DIR/brush_dataset_fused/ ready for Brush. Requires Pillow for
colors (falls back to gray).
"""
import argparse
import json
import os
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from arkit_to_colmap import voxel_downsample


def quat_to_rotmat(qw, qx, qy, qz):
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)],
        [2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)],
        [2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)],
    ])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("session", type=Path)
    ap.add_argument("ba_out", type=Path)
    ap.add_argument("--stride", type=int, default=2, help="sample every Nth depth pixel")
    ap.add_argument("--voxel", type=float, default=0.015, help="voxel merge size (m)")
    ap.add_argument("--max-depth", type=float, default=8.0, help="discard depth beyond this (m)")
    args = ap.parse_args()

    try:
        from PIL import Image
        have_pil = True
    except ImportError:
        have_pil = False
        print("note: Pillow not installed; fused points get neutral gray", file=sys.stderr)

    src_sparse = args.ba_out / "brush_dataset" / "sparse" / "0"
    if not (src_sparse / "images.txt").exists():
        sys.exit(f"no refined TXT model at {src_sparse} — run run_colmap.sh first")
    out = args.ba_out / "brush_dataset_fused"
    (out / "sparse" / "0").mkdir(parents=True, exist_ok=True)

    cams = {}
    for line in (src_sparse / "cameras.txt").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        p = line.split()
        cams[int(p[0])] = (int(p[2]), int(p[3]), *map(float, p[4:8]))

    shots = {}
    for sp in args.session.glob("shot_*.json"):
        d = json.loads(sp.read_text())
        shots[d["image"]] = d

    all_xyz, all_rgb = [], []
    used = 0
    lines = [l for l in (src_sparse / "images.txt").read_text().splitlines()
             if l.strip() and not l.startswith("#")]
    for l in lines[::2]:
        p = l.split()
        name = p[-1]
        d = shots.get(name)
        rec = d.get("depth") if d else None
        if not rec:
            continue
        R = quat_to_rotmat(*map(float, p[1:5]))
        t = np.array(list(map(float, p[5:8])))
        w, h, fx, fy, cx, cy = cams[int(p[-2])]
        dw, dh = rec["resolution"]
        z = np.fromfile(args.session / rec["file"], dtype="<f4").reshape(dh, dw)

        conf_name = rec.get("confidence")
        if conf_name and (args.session / conf_name).exists():
            conf = np.fromfile(args.session / conf_name, dtype=np.uint8).reshape(dh, dw)
            mask = conf == 2
        else:
            mask = np.ones((dh, dw), bool)
        strided = np.zeros((dh, dw), bool)
        strided[::args.stride, ::args.stride] = True
        mask &= strided & np.isfinite(z) & (z > 0.05) & (z < args.max_depth)
        if not mask.any():
            continue

        vs, us = np.nonzero(mask)
        zs = z[vs, us].astype(np.float64)
        # Refined intrinsics scaled to depth res; unproject in COLMAP convention
        # (+Z forward, v down) since the refined model is already COLMAP-space.
        fxd, fyd, cxd, cyd = fx * dw / w, fy * dh / h, cx * dw / w, cy * dh / h
        cam = np.stack([(us - cxd) / fxd * zs, (vs - cyd) / fyd * zs, zs], axis=1)
        all_xyz.append((cam - t) @ R)   # R^T (cam - t), row-wise

        if have_pil:
            img = np.asarray(Image.open(args.session / name).convert("RGB"))
            ih, iw = img.shape[:2]
            px = np.clip(((us + 0.5) * iw / dw).astype(int), 0, iw - 1)
            py = np.clip(((vs + 0.5) * ih / dh).astype(int), 0, ih - 1)
            all_rgb.append(img[py, px])
        else:
            all_rgb.append(np.full((len(zs), 3), 180, np.uint8))
        used += 1

    if not all_xyz:
        sys.exit("no depth data found — is this a LiDAR-tier session?")
    xyz = np.concatenate(all_xyz)
    rgb = np.concatenate(all_rgb)
    xyz, rgb = voxel_downsample(xyz, rgb, args.voxel)

    with open(out / "sparse" / "0" / "points3D.txt", "w") as f:
        f.write(f"# refined-pose LiDAR fusion\n# Number of points: {len(xyz)}\n")
        f.write("\n".join(
            f"{i} {p[0]:.6f} {p[1]:.6f} {p[2]:.6f} {c[0]} {c[1]} {c[2]} 0"
            for i, (p, c) in enumerate(zip(xyz, rgb), 1)) + "\n")
    shutil.copy2(src_sparse / "cameras.txt", out / "sparse" / "0" / "cameras.txt")
    shutil.copy2(src_sparse / "images.txt", out / "sparse" / "0" / "images.txt")
    link = out / "images"
    if not link.exists():
        os.symlink((args.ba_out / "images").resolve(), link)
    print(f"fused {used} shots through refined poses -> {len(xyz)} points")
    print(f"dataset: {out}")
    print(f"train  : brush {out}")


if __name__ == "__main__":
    main()
