"""
arkit_colmap.py — ARKit ⇄ COLMAP pose conversion + COLMAP text-model I/O.

The only subtle thing in the whole pipeline lives here: the coordinate flip.

  ARKit camera frame : +X right, +Y up,   −Z forward (looks down −Z).  transform = camera→world.
  COLMAP camera frame: +X right, +Y down, +Z forward (looks down +Z).  stores  world→camera.

The two camera frames differ by a 180° rotation about X (flip Y and Z): F = diag(1, −1, −1).
World stays in ARKit world coordinates; only the camera-local frame is flipped.

  [R_cw | t_cw] = inverse(T_wc)            # world→camera, still ARKit camera frame
  R_colmap = F @ R_cw ,  t_colmap = F @ t_cw

No external deps beyond numpy. Tested by validate.py (round-trip + post-triangulation cheirality).
"""
from __future__ import annotations
import numpy as np

CONVERSION_VERSION = "arkit-colmap-1.0.0"

F = np.diag([1.0, -1.0, -1.0])  # ARKit-cam → COLMAP-cam axis flip (its own inverse)


def colmap_pose_from_arkit(T_wc: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """ARKit 4x4 camera→world  →  COLMAP (R, t) world→camera."""
    T_wc = np.asarray(T_wc, dtype=np.float64).reshape(4, 4)
    R_wc, t_wc = T_wc[:3, :3], T_wc[:3, 3]
    R_cw = R_wc.T
    t_cw = -R_wc.T @ t_wc
    return F @ R_cw, F @ t_cw


def arkit_from_colmap(R_colmap: np.ndarray, t_colmap: np.ndarray) -> np.ndarray:
    """Inverse of colmap_pose_from_arkit — used by the round-trip self-test."""
    R_cw = F @ np.asarray(R_colmap, dtype=np.float64)
    t_cw = F @ np.asarray(t_colmap, dtype=np.float64)
    R_wc = R_cw.T
    t_wc = -R_cw.T @ t_cw
    T = np.eye(4)
    T[:3, :3], T[:3, 3] = R_wc, t_wc
    return T


def rotmat_to_quaternion(R: np.ndarray) -> np.ndarray:
    """3x3 rotation → unit quaternion (qw, qx, qy, qz), COLMAP's order. Shepperd's method."""
    R = np.asarray(R, dtype=np.float64)
    m00, m01, m02 = R[0]
    m10, m11, m12 = R[1]
    m20, m21, m22 = R[2]
    tr = m00 + m11 + m22
    if tr > 0:
        s = np.sqrt(tr + 1.0) * 2
        qw, qx, qy, qz = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
    elif m00 > m11 and m00 > m22:
        s = np.sqrt(1.0 + m00 - m11 - m22) * 2
        qw, qx, qy, qz = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
    elif m11 > m22:
        s = np.sqrt(1.0 + m11 - m00 - m22) * 2
        qw, qx, qy, qz = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
    else:
        s = np.sqrt(1.0 + m22 - m00 - m11) * 2
        qw, qx, qy, qz = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
    q = np.array([qw, qx, qy, qz], dtype=np.float64)
    return q / np.linalg.norm(q)


def quaternion_to_rotmat(q: np.ndarray) -> np.ndarray:
    """(qw,qx,qy,qz) → 3x3 rotation."""
    w, x, y, z = np.asarray(q, dtype=np.float64) / np.linalg.norm(q)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w)],
        [2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y)],
    ])


def intrinsics_pinhole(K: np.ndarray) -> tuple[float, float, float, float]:
    """3x3 intrinsics (row-major) → (fx, fy, cx, cy)."""
    K = np.asarray(K, dtype=np.float64).reshape(3, 3)
    return float(K[0, 0]), float(K[1, 1]), float(K[0, 2]), float(K[1, 2])


# ---------------------------------------------------------------------------
# COLMAP text-model parsers (only what the validator needs).
# ---------------------------------------------------------------------------
def _data_lines(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                yield line


def read_cameras(path) -> dict:
    """CAMERA_ID -> dict(model, w, h, params[])."""
    cams = {}
    for line in _data_lines(path):
        p = line.split()
        cams[int(p[0])] = dict(model=p[1], w=int(p[2]), h=int(p[3]),
                               params=[float(x) for x in p[4:]])
    return cams


def read_images(path) -> dict:
    """IMAGE_ID -> dict(q, t, camera_id, name, xys[], point3D_ids[]). Two lines per image."""
    imgs = {}
    lines = list(_data_lines(path))
    for i in range(0, len(lines), 2):
        h = lines[i].split()
        image_id = int(h[0])
        q = np.array([float(x) for x in h[1:5]])
        t = np.array([float(x) for x in h[5:8]])
        camera_id, name = int(h[8]), h[9]
        xys, p3d = [], []
        if i + 1 < len(lines):
            toks = lines[i + 1].split()
            for j in range(0, len(toks), 3):
                xys.append((float(toks[j]), float(toks[j + 1])))
                p3d.append(int(toks[j + 2]))
        imgs[image_id] = dict(q=q, t=t, camera_id=camera_id, name=name,
                              xys=xys, point3D_ids=p3d)
    return imgs


def read_points3D(path) -> dict:
    """POINT3D_ID -> xyz (np.array(3,))."""
    pts = {}
    for line in _data_lines(path):
        p = line.split()
        pts[int(p[0])] = np.array([float(p[1]), float(p[2]), float(p[3])])
    return pts
