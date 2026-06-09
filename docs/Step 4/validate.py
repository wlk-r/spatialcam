#!/usr/bin/env python3
"""
validate.py — two independent checks on the coordinate conversion.

  selftest   : synthetic round-trip + a hand-checkable convention assertion. No COLMAP,
               no data needed. Proves the conversion FUNCTION is mathematically consistent.

  reproject  : run AFTER point_triangulator on a real model dir. Reprojects every
               triangulated observation and reports cheirality (points in front of the
               camera) + reprojection error. This is the EMPIRICAL proof that the assumed
               ARKit/COLMAP conventions are correct: a wrong flip yields points behind the
               camera and huge error, or triangulation that barely produces points.

Usage:
  python validate.py selftest
  python validate.py reproject <model_dir_with_cameras_images_points3D>
"""
from __future__ import annotations
import sys
import numpy as np
from arkit_colmap import (colmap_pose_from_arkit, arkit_from_colmap,
                          quaternion_to_rotmat, read_cameras, read_images, read_points3D)


def _random_transform(rng):
    A = rng.normal(size=(3, 3))
    Q, _ = np.linalg.qr(A)
    if np.linalg.det(Q) < 0:
        Q[:, 0] *= -1
    T = np.eye(4)
    T[:3, :3] = Q
    T[:3, 3] = rng.normal(size=3) * 5
    return T


def selftest() -> bool:
    rng = np.random.default_rng(0)
    ok = True

    # 1) round-trip: arkit -> colmap -> arkit recovers the transform.
    max_err = 0.0
    for _ in range(2000):
        T = _random_transform(rng)
        R, t = colmap_pose_from_arkit(T)
        max_err = max(max_err, np.abs(arkit_from_colmap(R, t) - T).max())
    print(f"round-trip max abs error: {max_err:.2e}", "OK" if max_err < 1e-9 else "FAIL")
    ok &= max_err < 1e-9

    # 2) convention sanity: ARKit identity pose (camera at world origin, axes aligned).
    #    A point ARKit sees in front of it is at world −Z. After conversion it must land
    #    in front of the COLMAP camera, i.e. X_cam.z > 0.
    R, t = colmap_pose_from_arkit(np.eye(4))
    front_world = np.array([0.0, 0.0, -1.0])   # in front of an ARKit camera
    z_cam = (R @ front_world + t)[2]
    print(f"front-of-camera z in COLMAP frame: {z_cam:+.3f}", "OK" if z_cam > 0 else "FAIL")
    ok &= z_cam > 0

    print("SELFTEST", "PASS" if ok else "FAIL")
    return ok


def reproject(model_dir: str) -> bool:
    from pathlib import Path
    d = Path(model_dir)
    cams = read_cameras(d / "cameras.txt")
    imgs = read_images(d / "images.txt")
    pts = read_points3D(d / "points3D.txt")
    if not pts:
        sys.exit("points3D.txt is empty — run point_triangulator first, then re-check.")

    errors, behind, total = [], 0, 0
    for img in imgs.values():
        R = quaternion_to_rotmat(img["q"])
        t = img["t"]
        cam = cams[img["camera_id"]]
        if cam["model"] == "SIMPLE_PINHOLE":
            f, cx, cy = cam["params"][:3]
            fx = fy = f
        else:
            fx, fy, cx, cy = cam["params"][:4]
        for (u, v), pid in zip(img["xys"], img["point3D_ids"]):
            if pid < 0 or pid not in pts:
                continue
            total += 1
            Xc = R @ pts[pid] + t
            if Xc[2] <= 0:
                behind += 1
                continue
            pu = fx * Xc[0] / Xc[2] + cx
            pv = fy * Xc[1] / Xc[2] + cy
            errors.append(np.hypot(pu - u, pv - v))

    if not errors:
        sys.exit("No valid observations to reproject.")
    e = np.array(errors)
    print(f"observations: {total}   behind-camera: {behind} ({100*behind/total:.2f}%)")
    print(f"reprojection error px  median={np.median(e):.3f}  mean={e.mean():.3f}  p95={np.percentile(e,95):.3f}")
    # Healthy known-pose triangulation: almost nothing behind camera, sub-pixel-ish median.
    ok = (behind / total < 0.01) and (np.median(e) < 2.0)
    print("REPROJECT", "PASS" if ok else "FAIL — check the flip / poses")
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    elif cmd == "reproject":
        if len(sys.argv) < 3:
            sys.exit("reproject needs a model dir")
        sys.exit(0 if reproject(sys.argv[2]) else 1)
    else:
        sys.exit(__doc__)
