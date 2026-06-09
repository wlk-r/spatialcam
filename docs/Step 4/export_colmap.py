#!/usr/bin/env python3
"""
export_colmap.py — turn a capture session into a COLMAP input model with KNOWN poses.

Two modes:
  1. No --database  : copies images, writes a model with sequential (filename-sorted) IDs.
                      Good for inspection; NOT safe to feed to point_triangulator yet.
  2. With --database: writes a model whose IMAGE_ID/CAMERA_ID match the COLMAP database,
                      which is what point_triangulator requires. Run feature_extractor +
                      matcher first, then call this with the database to get the real model.

Output layout:
  <out>/images/shot_NNNN.png
  <out>/sparse/manual/{cameras.txt, images.txt, points3D.txt}   (points3D empty until step 5/triangulation)

See run_colmap.sh for the full extract → match → export → triangulate → bundle-adjust recipe.
"""
from __future__ import annotations
import argparse, json, shutil, sqlite3, sys
from pathlib import Path
import numpy as np
from arkit_colmap import (colmap_pose_from_arkit, rotmat_to_quaternion,
                          intrinsics_pinhole, CONVERSION_VERSION)


def load_shots(session: Path):
    shots = sorted(session.glob("shot_*.json"))
    if not shots:
        sys.exit(f"No shot_*.json found in {session}")
    out = []
    for s in shots:
        d = json.loads(s.read_text())
        out.append(d)
    return out


def db_name_map(database: Path) -> dict:
    """basename -> (image_id, camera_id) from a COLMAP database."""
    conn = sqlite3.connect(str(database))
    try:
        rows = conn.execute("SELECT image_id, name, camera_id FROM images").fetchall()
    finally:
        conn.close()
    return {name: (int(iid), int(cid)) for iid, name, cid in rows}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session", required=True, type=Path, help="session_<...> folder")
    ap.add_argument("--out", required=True, type=Path, help="output model dir")
    ap.add_argument("--database", type=Path, help="COLMAP database.db (for DB-aligned IDs)")
    args = ap.parse_args()

    shots = load_shots(args.session)
    images_dir = args.out / "images"
    model_dir = args.out / "sparse" / "manual"
    images_dir.mkdir(parents=True, exist_ok=True)
    model_dir.mkdir(parents=True, exist_ok=True)

    # Copy images (idempotent).
    for sh in shots:
        src = args.session / sh["image"]
        if src.exists():
            shutil.copy2(src, images_dir / sh["image"])
        else:
            print(f"  warn: missing image {src}", file=sys.stderr)

    name_map = db_name_map(args.database) if args.database else None
    if name_map is None:
        print("No --database: writing sequential IDs (inspection only; re-run with the "
              "database before point_triangulator).", file=sys.stderr)

    cam_lines, img_lines = [], []
    for seq, sh in enumerate(shots, start=1):
        name = sh["image"]
        if name_map is not None:
            if name not in name_map:
                sys.exit(f"{name} not in database — was it extracted? Names must match.")
            image_id, camera_id = name_map[name]
        else:
            image_id = camera_id = seq

        w, h = sh["resolution"]
        fx, fy, cx, cy = intrinsics_pinhole(np.array(sh["intrinsics"]))
        cam_lines.append(f"{camera_id} PINHOLE {w} {h} {fx:.10g} {fy:.10g} {cx:.10g} {cy:.10g}")

        R, t = colmap_pose_from_arkit(np.array(sh["transform_camera_to_world"]))
        qw, qx, qy, qz = rotmat_to_quaternion(R)
        img_lines.append(
            f"{image_id} {qw:.10g} {qx:.10g} {qy:.10g} {qz:.10g} "
            f"{t[0]:.10g} {t[1]:.10g} {t[2]:.10g} {camera_id} {name}")
        img_lines.append("")  # empty POINTS2D — point_triangulator fills these

    (model_dir / "cameras.txt").write_text(
        "# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[fx,fy,cx,cy]\n" + "\n".join(cam_lines) + "\n")
    (model_dir / "images.txt").write_text(
        "# IMAGE_ID, QW,QX,QY,QZ, TX,TY,TZ, CAMERA_ID, NAME\n#   then a (possibly empty) POINTS2D line\n"
        + "\n".join(img_lines) + "\n")
    (model_dir / "points3D.txt").write_text(
        "# POINT3D_ID, X,Y,Z, R,G,B, ERROR, TRACK[]  (empty until triangulation / step-5 seed)\n")

    # Stamp the conversion version back into a copy of the manifest for provenance.
    man_path = args.session / "manifest.json"
    if man_path.exists():
        man = json.loads(man_path.read_text())
        man["arkit_to_colmap_conversion_version"] = CONVERSION_VERSION
        (args.out / "manifest.json").write_text(json.dumps(man, indent=2, sort_keys=True))

    print(f"Wrote {len(shots)} cameras/images to {model_dir} "
          f"({'DB-aligned' if name_map else 'sequential'} IDs), images in {images_dir}")


if __name__ == "__main__":
    main()
