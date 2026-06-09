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

  --voxel METERS  voxel-downsample the seed cloud (0 = keep all points; default 0)
  --copy          copy JPEGs instead of symlinking them into out/images/
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
    keys = np.floor(xyz / voxel).astype(np.int64)
    _, inv, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    nv = counts.shape[0]
    sums = np.zeros((nv, 3))
    csum = np.zeros((nv, 3))
    np.add.at(sums, inv, xyz)
    np.add.at(csum, inv, rgb.astype(np.float64))
    return sums / counts[:, None], np.rint(csum / counts[:, None]).astype(np.uint8)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--voxel", type=float, default=0.0,
                    help="voxel size in meters for seed-cloud downsample (0 = keep all)")
    ap.add_argument("--copy", action="store_true", help="copy images instead of symlinking")
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
    skipped = 0
    for cam_id, jp in enumerate(shots, start=1):
        d = json.loads(jp.read_text())
        if d.get("tracking_state") not in (None, "normal"):
            skipped += 1
            continue
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

    # points3D.txt from seed cloud
    ply = session / "seed_points.ply"
    xyz, rgb = read_ply_xyzrgb(ply)
    n_raw = len(xyz)
    if args.voxel > 0:
        xyz, rgb = voxel_downsample(xyz, rgb, args.voxel)
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
          + (f" (voxel {args.voxel} m, from {n_raw})" if args.voxel > 0 else f" (all {n_raw})"))
    print(f"scene extent   : {ext[0]:.2f} x {ext[1]:.2f} x {ext[2]:.2f} m")
    print(f"output         : {out}")
    print(f"train          : brush {out}")


if __name__ == "__main__":
    main()
