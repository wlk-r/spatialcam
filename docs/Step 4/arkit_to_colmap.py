#!/usr/bin/env python3
"""
arkit_to_colmap.py

Convert an ARKit/LiDAR capture session (per-shot JSON poses + intrinsics, JPEGs,
and a world-space seed point cloud) into a COLMAP `sparse/0` model that Brush /
gsplat / nerfstudio can train on directly -- no SfM, no Metashape.

What it does:
  * Reads every shot_*.json  -> per-image PINHOLE camera (focal varies per shot)
  * Converts ARKit camera->world pose into COLMAP world->camera (quat + t)
  * Reformats seed_points.ply (world coords, XYZ+RGB) into points3D.txt as-is
    (world frame is unchanged; only the camera-local axes are converted)
  * Lays out  out/images/  +  out/sparse/0/{cameras,images,points3D}.txt

Coordinate conversion (the manifest's "step 4"):
  ARKit camera axes:  +X right, +Y up,   -Z forward
  COLMAP camera axes: +X right, +Y down, +Z forward   => flip Y,Z = diag(1,-1,-1)
  ARKit gives camera->world; COLMAP wants world->camera => invert.
    R_w2c = M @ R_c2w^T ,  t_w2c = -R_w2c @ t_c2w ,  M = diag(1,-1,-1)

Usage:
  python3 arkit_to_colmap.py SESSION_DIR OUT_DIR [--voxel 0.0] [--copy]
                             [--fuse-depth] [--fuse-stride 2] [--fuse-voxel 0.015]
                             [--fuse-max-depth 8.0]

  --voxel METERS     voxel-downsample the final cloud (0 = keep all points; default 0)
  --copy             copy JPEGs instead of symlinking them into out/images/
  --fuse-depth       unproject per-shot LiDAR depth (confidence == 2 only) to world,
                     sample colors from the JPEGs, voxel-merge with the seed cloud.
                     Densifies near-field init the way Metashape's seed does
                     (arkit_direct_to_brush.md §6). Decodes every JPEG once for
                     colors, so expect ~1-2 min on a long session (needs Pillow;
                     falls back to gray without it).
  --fuse-stride N    sample every Nth depth pixel in x and y (default 2)
  --fuse-voxel M     voxel size for merging fused+seed points (default 0.015,
                     matching the app's seed voxel)
  --fuse-max-depth M discard depth samples beyond M meters (default 8.0; LiDAR
                     noise grows past ~5 m)
"""

import argparse
import json
import os
import struct
import sys
from pathlib import Path

import numpy as np

# ARKit-cam -> COLMAP-cam axis flip (flip Y and Z)
M = np.diag([1.0, -1.0, -1.0])


# ---------------------------------------------------------------- pose helpers
def mat2qvec(R):
    """Rotation matrix -> COLMAP quaternion order (qw, qx, qy, qz), normalized."""
    R = np.asarray(R, dtype=np.float64)
    tr = R[0, 0] + R[1, 1] + R[2, 2]
    if tr > 0:
        r = np.sqrt(1.0 + tr)
        s = 0.5 / r
        q = np.array([0.5 * r,
                      (R[2, 1] - R[1, 2]) * s,
                      (R[0, 2] - R[2, 0]) * s,
                      (R[1, 0] - R[0, 1]) * s])
    else:
        i = int(np.argmax([R[0, 0], R[1, 1], R[2, 2]]))
        if i == 0:
            r = np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]); s = 0.5 / r
            q = np.array([(R[2, 1] - R[1, 2]) * s, 0.5 * r,
                          (R[0, 1] + R[1, 0]) * s, (R[0, 2] + R[2, 0]) * s])
        elif i == 1:
            r = np.sqrt(1.0 - R[0, 0] + R[1, 1] - R[2, 2]); s = 0.5 / r
            q = np.array([(R[0, 2] - R[2, 0]) * s, (R[0, 1] + R[1, 0]) * s,
                          0.5 * r, (R[1, 2] + R[2, 1]) * s])
        else:
            r = np.sqrt(1.0 - R[0, 0] - R[1, 1] + R[2, 2]); s = 0.5 / r
            q = np.array([(R[1, 0] - R[0, 1]) * s, (R[0, 2] + R[2, 0]) * s,
                          (R[1, 2] + R[2, 1]) * s, 0.5 * r])
    if q[0] < 0:
        q = -q
    return q / np.linalg.norm(q)


def arkit_to_colmap_pose(T_c2w):
    """4x4 camera->world (ARKit) -> (qvec, tvec) world->camera (COLMAP)."""
    T = np.asarray(T_c2w, dtype=np.float64)
    R_c2w = T[:3, :3]
    t_c2w = T[:3, 3]
    R_w2c = M @ R_c2w.T
    t_w2c = -R_w2c @ t_c2w
    return mat2qvec(R_w2c), t_w2c


# ---------------------------------------------------------------- PLY reader
_PLY_NP = {
    "char": "i1", "uchar": "u1", "int8": "i1", "uint8": "u1",
    "short": "i2", "ushort": "u2", "int16": "i2", "uint16": "u2",
    "int": "i4", "uint": "u4", "int32": "i4", "uint32": "u4",
    "float": "f4", "float32": "f4", "double": "f8", "float64": "f8",
}


def read_ply_xyzrgb(path):
    """Read XYZ + RGB from an ascii or binary_little/big_endian PLY. Returns (N,3) f64, (N,3) u8."""
    with open(path, "rb") as f:
        if f.readline().strip() != b"ply":
            raise ValueError("not a PLY file")
        fmt = None
        n = 0
        props = []          # (name, type) for the vertex element
        in_vertex = False
        while True:
            line = f.readline().decode("ascii").strip()
            if line.startswith("format"):
                fmt = line.split()[1]
            elif line.startswith("element"):
                _, name, count = line.split()
                in_vertex = name == "vertex"
                if in_vertex:
                    n = int(count)
            elif line.startswith("property") and in_vertex:
                parts = line.split()
                props.append((parts[-1], parts[1]))   # (name, type); list props unsupported
            elif line == "end_header":
                break
        names = [p[0] for p in props]
        ix, iy, iz = names.index("x"), names.index("y"), names.index("z")
        ir, ig, ib = names.index("red"), names.index("green"), names.index("blue")

        if fmt == "ascii":
            data = np.loadtxt(f, max_rows=n)
            xyz = data[:, [ix, iy, iz]].astype(np.float64)
            rgb = data[:, [ir, ig, ib]].astype(np.uint8)
        else:
            order = "<" if "little" in fmt else ">"
            dt = np.dtype([(nm, order + _PLY_NP[ty]) for nm, ty in props])
            data = np.frombuffer(f.read(n * dt.itemsize), dtype=dt, count=n)
            xyz = np.stack([data["x"], data["y"], data["z"]], axis=1).astype(np.float64)
            rgb = np.stack([data["red"], data["green"], data["blue"]], axis=1).astype(np.uint8)
    return xyz, rgb


def voxel_downsample(xyz, rgb, voxel):
    """Average points (and colors) within each voxel cell."""
    keys3 = np.floor(xyz / voxel).astype(np.int64)
    if np.abs(keys3).max() >= 2 ** 20:
        raise ValueError(f"scene too large for {voxel} m voxel packing (> ±15 km)")
    # Pack the 3 voxel indices into one int64: unique() on a flat array lexsorts
    # ~10x faster than axis=0 on the multi-million-point fused clouds.
    keys = ((keys3[:, 0] + 2 ** 20) << 42) | ((keys3[:, 1] + 2 ** 20) << 21) | (keys3[:, 2] + 2 ** 20)
    _, inv, counts = np.unique(keys, return_inverse=True, return_counts=True)
    nv = counts.shape[0]
    sums = np.zeros((nv, 3))
    csum = np.zeros((nv, 3))
    np.add.at(sums, inv, xyz)
    np.add.at(csum, inv, rgb.astype(np.float64))
    return sums / counts[:, None], np.rint(csum / counts[:, None]).astype(np.uint8)


# ---------------------------------------------------------------- depth fusion
def fuse_depth_points(session, shots, stride, max_depth):
    """Unproject confidence==2 LiDAR depth pixels to world coords with JPEG colors.

    `shots` are the parsed sidecar dicts that passed the tracking filter.
    Returns (N,3) float64 xyz and (N,3) uint8 rgb (unmerged; caller voxel-merges).
    """
    try:
        from PIL import Image
        have_pil = True
    except ImportError:
        have_pil = False
        print("note: Pillow not installed; fused points get neutral gray colors",
              file=sys.stderr)

    all_xyz, all_rgb = [], []
    used = 0
    for d in shots:
        rec = d.get("depth")
        if not rec:
            continue
        dpath = session / rec["file"]
        if not dpath.exists():
            continue
        dw, dh = rec["resolution"]
        z = np.fromfile(dpath, dtype="<f4").reshape(dh, dw)

        conf_name = rec.get("confidence")
        if conf_name and (session / conf_name).exists():
            conf = np.fromfile(session / conf_name, dtype=np.uint8).reshape(dh, dw)
            mask = conf == 2          # high confidence only: edges/long range seed fuzz
        else:
            mask = np.ones((dh, dw), bool)
        strided = np.zeros((dh, dw), bool)
        strided[::stride, ::stride] = True
        mask &= strided & np.isfinite(z) & (z > 0.05) & (z < max_depth)
        if not mask.any():
            continue

        vs, us = np.nonzero(mask)
        zs = z[vs, us].astype(np.float64)
        K = d["intrinsics"]
        w, h = d["resolution"]
        fx, fy = K[0][0] * dw / w, K[1][1] * dh / h
        cx, cy = K[0][2] * dw / w, K[1][2] * dh / h
        # ARKit camera: +X right, +Y up, -Z forward; image v points down => the
        # pinhole lift is (x', -y', -z), same flipYZ as Apple's scene-depth sample.
        xc = (us - cx) / fx * zs
        yc = -(vs - cy) / fy * zs
        cam = np.stack([xc, yc, -zs, np.ones_like(zs)], axis=1)
        T = np.asarray(d["transform_camera_to_world"], dtype=np.float64)
        all_xyz.append((T @ cam.T).T[:, :3])

        if have_pil:
            img = np.asarray(Image.open(session / d["image"]).convert("RGB"))
            ih, iw = img.shape[:2]
            px = np.clip(((us + 0.5) * iw / dw).astype(int), 0, iw - 1)
            py = np.clip(((vs + 0.5) * ih / dh).astype(int), 0, ih - 1)
            all_rgb.append(img[py, px])
        else:
            all_rgb.append(np.full((len(zs), 3), 180, np.uint8))
        used += 1

    if not all_xyz:
        return np.zeros((0, 3)), np.zeros((0, 3), np.uint8)
    print(f"depth fusion   : {used} shots unprojected (conf==2, stride {stride}, <{max_depth} m)")
    return np.concatenate(all_xyz), np.concatenate(all_rgb)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--voxel", type=float, default=0.0,
                    help="voxel size in meters for final-cloud downsample (0 = keep all)")
    ap.add_argument("--copy", action="store_true", help="copy images instead of symlinking")
    ap.add_argument("--fuse-depth", action="store_true",
                    help="fuse per-shot LiDAR depth (confidence==2) into the seed cloud")
    ap.add_argument("--no-seed", action="store_true",
                    help="ignore seed_points.ply (use with --fuse-depth for sessions "
                         "captured before the Y-sign fix, whose seed clouds are mirrored)")
    ap.add_argument("--fuse-stride", type=int, default=2,
                    help="sample every Nth depth pixel when fusing (default 2)")
    ap.add_argument("--fuse-voxel", type=float, default=0.015,
                    help="voxel size for merging fused+seed points (default 0.015)")
    ap.add_argument("--fuse-max-depth", type=float, default=8.0,
                    help="discard depth samples beyond this range in meters (default 8)")
    args = ap.parse_args()

    session, out = args.session, args.out
    sparse = out / "sparse" / "0"
    img_out = out / "images"
    sparse.mkdir(parents=True, exist_ok=True)
    img_out.mkdir(parents=True, exist_ok=True)

    shots = sorted(session.glob("shot_*.json"))
    if not shots:
        sys.exit(f"no shot_*.json found in {session}")

    cam_lines, img_lines = [], []
    accepted = []
    skipped = 0
    for cam_id, jp in enumerate(shots, start=1):
        d = json.loads(jp.read_text())
        if d.get("tracking_state") not in (None, "normal"):
            skipped += 1
            continue
        accepted.append(d)
        K = d["intrinsics"]
        fx, fy, cx, cy = K[0][0], K[1][1], K[0][2], K[1][2]
        w, h = d["resolution"]
        name = d["image"]

        # link / copy the image
        dst = img_out / name
        src = (session / name).resolve()
        if not dst.exists():
            if args.copy:
                import shutil
                shutil.copy2(src, dst)
            else:
                os.symlink(src, dst)

        q, t = arkit_to_colmap_pose(d["transform_camera_to_world"])
        # one PINHOLE camera per image (focal length drifts shot-to-shot)
        cam_lines.append(f"{cam_id} PINHOLE {w} {h} {fx:.6f} {fy:.6f} {cx:.6f} {cy:.6f}")
        img_lines.append(
            f"{cam_id} {q[0]:.9f} {q[1]:.9f} {q[2]:.9f} {q[3]:.9f} "
            f"{t[0]:.9f} {t[1]:.9f} {t[2]:.9f} {cam_id} {name}"
        )
        img_lines.append("")   # COLMAP per-image 2D-points line (empty for init)

    # cameras.txt
    with open(sparse / "cameras.txt", "w") as f:
        f.write("# Camera list\n# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        f.write(f"# Number of cameras: {len(cam_lines)}\n")
        f.write("\n".join(cam_lines) + "\n")

    # images.txt
    with open(sparse / "images.txt", "w") as f:
        f.write("# Image list\n# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("# (followed by one line of POINTS2D, empty here)\n")
        f.write(f"# Number of images: {len(cam_lines)}\n")
        f.write("\n".join(img_lines) + "\n")

    # points3D.txt from seed cloud (+ optional LiDAR depth fusion)
    ply = session / "seed_points.ply"
    if args.no_seed:
        xyz, rgb = np.zeros((0, 3)), np.zeros((0, 3), np.uint8)
    elif ply.exists():
        xyz, rgb = read_ply_xyzrgb(ply)
    else:
        print(f"warning: no seed_points.ply in {session}", file=sys.stderr)
        xyz, rgb = np.zeros((0, 3)), np.zeros((0, 3), np.uint8)
    n_raw = len(xyz)

    if args.fuse_depth:
        fxyz, frgb = fuse_depth_points(session, accepted, args.fuse_stride, args.fuse_max_depth)
        xyz = np.concatenate([xyz, fxyz])
        rgb = np.concatenate([rgb, frgb])

    # --voxel governs when set; otherwise fusion still needs a merge pass to
    # dedupe fused points against the seed cloud (and against themselves).
    merge_voxel = args.voxel if args.voxel > 0 else (args.fuse_voxel if args.fuse_depth else 0.0)
    if merge_voxel > 0 and len(xyz):
        xyz, rgb = voxel_downsample(xyz, rgb, merge_voxel)
    ext = xyz.max(0) - xyz.min(0)
    with open(sparse / "points3D.txt", "w") as f:
        f.write("# 3D point list\n# POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[]\n")
        f.write(f"# Number of points: {len(xyz)}\n")
        rows = [
            f"{i} {p[0]:.6f} {p[1]:.6f} {p[2]:.6f} {c[0]} {c[1]} {c[2]} 0"
            for i, (p, c) in enumerate(zip(xyz, rgb), start=1)
        ]
        f.write("\n".join(rows) + "\n")

    print(f"cameras/images : {len(cam_lines)} written ({skipped} skipped: bad tracking)")
    print(f"points3D       : {len(xyz)} written"
          + (f" (merged at {merge_voxel} m; seed cloud contributed {n_raw})"
             if merge_voxel > 0 else f" (all {n_raw} seed points)"))
    print(f"scene extent   : {ext[0]:.2f} x {ext[1]:.2f} x {ext[2]:.2f} m")
    print(f"output         : {out}")
    print(f"train          : brush {out}")


if __name__ == "__main__":
    main()
