#!/usr/bin/env python3
"""
spatialcam session -> Metashape aligned project -> Brush-ready COLMAP PINHOLE dataset.

Run through Metashape's bundled Python:
  /Applications/MetashapePro.app/Contents/MacOS/MetashapePro -r metashape_capture.py \
    /path/to/session_<ts> /path/to/out
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import Metashape


def load_shots(session: Path) -> list[dict]:
    shots = []
    for sidecar in sorted(session.glob("shot_*.json")):
        data = json.loads(sidecar.read_text())
        image = session / data["image"]
        if not image.exists():
            print(f"warn: skipping {sidecar.name}; missing {data['image']}")
            continue
        shots.append(data)
    if not shots:
        raise SystemExit(f"No usable shot_*.json files found in {session}")
    return shots


def arkit_position(transform_camera_to_world) -> list[float]:
    return [float(transform_camera_to_world[0][3]), float(transform_camera_to_world[1][3]), float(transform_camera_to_world[2][3])]


def arkit_to_metashape_transform(T) -> "Metashape.Matrix":
    """ARKit camera->world (row-major) -> Metashape camera->world transform.

    Metashape's camera frame is +X right, +Y down, +Z forward (like COLMAP), while ARKit's
    is +X right, +Y up, -Z forward. Negating the camera-local Y and Z axes converts between
    them; the world/chunk frame is left as ARKit world (consistent with the position refs and
    the COLMAP export, which also only flips the camera-local frame).
    """
    M = [[float(T[i][0]), -float(T[i][1]), -float(T[i][2]), float(T[i][3])] for i in range(4)]
    return Metashape.Matrix(M)


def apply_calibration(sensor: Metashape.Sensor, shot: dict, fixed: bool) -> None:
    """Load one shot's ARKit intrinsics into a sensor's calibration.

    Focus is left unlocked on the device, so fx/fy/cx/cy drift frame to frame. We pass
    those recorded per-frame values through verbatim. Metashape's `f`/`b1` split carries
    fx and fy independently (fx = f + b1, fy = f), and cx/cy are stored as offsets from
    the image center while spatialcam stores absolute principal points.
    """
    k = shot["intrinsics"]
    width, height = shot["resolution"]
    fx, fy = float(k[0][0]), float(k[1][1])

    calibration = Metashape.Calibration()
    calibration.width = int(width)
    calibration.height = int(height)
    calibration.f = fy
    calibration.b1 = fx - fy
    calibration.cx = float(k[0][2]) - width / 2.0
    calibration.cy = float(k[1][2]) - height / 2.0

    sensor.user_calib = calibration
    sensor.fixed_calibration = fixed
    sensor.fixed = False


def configure_per_frame_sensors(chunk: Metashape.Chunk, by_label: dict, fixed: bool) -> None:
    """Give every photo its own calibration group so per-frame ARKit intrinsics survive.

    `addPhotos` collapses all same-resolution images into a single sensor, which forces one
    shared calibration and discards the unlocked-focus drift we deliberately recorded. One
    sensor per photo keeps each frame's fx/fy/cx/cy. A single-image group cannot self-
    calibrate, so these are meant to stay fixed (`--fixed-intrinsics`) and be trusted as data;
    leaving them free lets Metashape diverge per camera.
    """
    shared = list(chunk.sensors)
    base = shared[0] if shared else None
    for camera in chunk.cameras:
        shot = by_label.get(camera.label)
        if not shot:
            print(f"warn: no sidecar for camera {camera.label}; leaving on shared sensor")
            continue
        width, height = int(shot["resolution"][0]), int(shot["resolution"][1])
        sensor = chunk.addSensor()
        sensor.label = f"arkit_{camera.label}"
        sensor.type = base.type if base is not None else Metashape.Sensor.Type.Frame
        # A fresh sensor defaults to zero pixel dimensions; Metashape refuses to load images
        # into it. Carry the image size (and base pixel/focal metadata) over explicitly.
        sensor.width = width
        sensor.height = height
        if base is not None:
            try:
                sensor.pixel_size = base.pixel_size
                sensor.focal_length = base.focal_length
            except Exception:
                pass
        try:
            sensor.rolling_shutter = Metashape.Shutter.Model.Full
        except Exception:
            pass
        apply_calibration(sensor, shot, fixed=fixed)
        camera.sensor = sensor

    orphaned = [s for s in shared if all(c.sensor is not s for c in chunk.cameras)]
    if orphaned:
        chunk.remove(orphaned)


def configure_lens_grouped_sensors(chunk: Metashape.Chunk, by_label: dict, bin_width: float, fixed: bool) -> None:
    """Cluster photos into calibration groups by recorded lens_position (sidecar v2).

    Unlike per-frame sensors (single-image groups, which cannot self-calibrate), a
    lens-position bin holds many images at effectively the same focus, so Metashape
    has enough observations to refine f/cx/cy and distortion per group while the
    recorded ARKit intrinsics (averaged over the group) serve as the initialization.
    Cameras without lens_position (v1 captures) stay on the shared sensor.
    """
    bins: dict[int, list] = {}
    missing = 0
    for camera in chunk.cameras:
        shot = by_label.get(camera.label)
        lens_position = shot.get("lens_position") if shot else None
        if lens_position is None:
            missing += 1
            continue
        bins.setdefault(int(round(lens_position / bin_width)), []).append((camera, shot))
    if missing:
        print(f"warn: {missing} cameras lack lens_position; left on shared sensor")

    shared = list(chunk.sensors)
    base = shared[0] if shared else None
    for key, members in sorted(bins.items()):
        width, height = (int(v) for v in members[0][1]["resolution"])
        n = len(members)
        fx = sum(s["intrinsics"][0][0] for _, s in members) / n
        fy = sum(s["intrinsics"][1][1] for _, s in members) / n
        cx = sum(s["intrinsics"][0][2] for _, s in members) / n
        cy = sum(s["intrinsics"][1][2] for _, s in members) / n

        sensor = chunk.addSensor()
        sensor.label = f"arkit_lens_{key}"
        sensor.type = base.type if base is not None else Metashape.Sensor.Type.Frame
        sensor.width = width
        sensor.height = height
        if base is not None:
            try:
                sensor.pixel_size = base.pixel_size
                sensor.focal_length = base.focal_length
            except Exception:
                pass
        try:
            sensor.rolling_shutter = Metashape.Shutter.Model.Full
        except Exception:
            pass

        calibration = Metashape.Calibration()
        calibration.width = width
        calibration.height = height
        calibration.f = fy
        calibration.b1 = fx - fy
        calibration.cx = cx - width / 2.0
        calibration.cy = cy - height / 2.0
        sensor.user_calib = calibration
        sensor.fixed_calibration = fixed
        sensor.fixed = False
        for camera, _ in members:
            camera.sensor = sensor
        print(f"lens group {key}: {n} photos (lens_position ~{key * bin_width:.2f}, fx ~{fx:.1f})")

    if not missing:
        orphaned = [s for s in shared if all(c.sensor is not s for c in chunk.cameras)]
        if orphaned:
            chunk.remove(orphaned)


def make_document(session: Path, out: Path, shots: list[dict], location_accuracy: float, fixed_intrinsics: bool, orientation_priors: bool, rotation_accuracy: float, lens_groups: float | None) -> tuple[Metashape.Document, Metashape.Chunk]:
    doc = Metashape.Document()
    chunk = doc.addChunk()
    chunk.label = "spatialcam"

    image_paths = [str(session / shot["image"]) for shot in shots]
    chunk.addPhotos(image_paths, strip_extensions=True, load_reference=False)

    by_label = {Path(shot["image"]).stem: shot for shot in shots}
    chunk.camera_location_accuracy = Metashape.Vector([location_accuracy] * 3)
    if orientation_priors:
        chunk.camera_rotation_accuracy = Metashape.Vector([rotation_accuracy] * 3)

    for camera in chunk.cameras:
        shot = by_label.get(camera.label)
        if not shot:
            print(f"warn: no sidecar for camera {camera.label}")
            continue
        transform = shot["transform_camera_to_world"]
        camera.reference.location = Metashape.Vector(arkit_position(transform))
        camera.reference.location_accuracy = Metashape.Vector([location_accuracy] * 3)
        camera.reference.enabled = True

        if orientation_priors:
            # Seed the full 6DoF pose, then derive the reference rotation from that same
            # transform via Metashape's own converter so the YPR convention is never guessed.
            camera.transform = arkit_to_metashape_transform(transform)
            ypr = Metashape.Utils.mat2ypr(camera.transform.rotation())
            camera.reference.rotation = ypr
            camera.reference.rotation_accuracy = Metashape.Vector([rotation_accuracy] * 3)

    if lens_groups is not None:
        configure_lens_grouped_sensors(chunk, by_label, bin_width=lens_groups, fixed=fixed_intrinsics)
    else:
        configure_per_frame_sensors(chunk, by_label, fixed=fixed_intrinsics)

    doc.save(str(out / "project.psx"))
    return doc, doc.chunks[0]


def align_and_optimize(
    doc: Metashape.Document,
    chunk: Metashape.Chunk,
    *,
    downscale: int,
    keypoint_limit: int,
    tiepoint_limit: int,
    fixed_intrinsics: bool,
) -> None:
    chunk.matchPhotos(
        downscale=downscale,
        generic_preselection=True,
        reference_preselection=True,
        reference_preselection_mode=Metashape.ReferencePreselectionSource,
        keypoint_limit=keypoint_limit,
        tiepoint_limit=tiepoint_limit,
        filter_mask=False,
        keep_keypoints=True,
    )
    doc.save()

    chunk.alignCameras(adaptive_fitting=True, reset_alignment=True)
    doc.save()

    chunk.optimizeCameras(
        fit_f=not fixed_intrinsics,
        fit_cx=not fixed_intrinsics,
        fit_cy=not fixed_intrinsics,
        fit_b1=False,
        fit_b2=False,
        fit_k1=not fixed_intrinsics,
        fit_k2=not fixed_intrinsics,
        fit_k3=not fixed_intrinsics,
        fit_k4=False,
        fit_p1=not fixed_intrinsics,
        fit_p2=not fixed_intrinsics,
        adaptive_fitting=True,
    )
    doc.save()


def export_brush_dataset(chunk: Metashape.Chunk, out: Path) -> Path:
    dataset = out / "brush_dataset"
    if dataset.exists():
        shutil.rmtree(dataset)
    dataset.mkdir(parents=True)

    compression = Metashape.ImageCompression()
    compression.jpeg_quality = 92

    chunk.exportCameras(
        path=str(dataset / "model.txt"),
        format=Metashape.CamerasFormatColmap,
        save_points=True,
        save_images=True,
        use_labels=True,
        convert_to_pinhole=True,
        image_path="{filename}.jpg",
        image_compression=compression,
        binary=False,
    )

    # Metashape writes model.txt next to images/ and sparse/0/. Brush only needs the
    # standard COLMAP layout; remove the descriptor if it exists.
    descriptor = dataset / "model.txt"
    if descriptor.exists():
        descriptor.unlink()
    normalize_simple_pinhole(dataset / "sparse" / "0" / "cameras.txt")
    return dataset


def normalize_simple_pinhole(cameras_txt: Path) -> None:
    if not cameras_txt.exists():
        return
    lines = cameras_txt.read_text().splitlines()
    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue
        parts = stripped.split()
        if len(parts) == 7 and parts[1] == "SIMPLE_PINHOLE":
            camera_id, _, width, height, f, cx, cy = parts
            out.append(f"{camera_id} PINHOLE {width} {height} {f} {f} {cx} {cy}")
        else:
            out.append(line)
    cameras_txt.write_text("\n".join(out) + "\n")


def copy_provenance(session: Path, out: Path, shots: list[dict], aligned: int, total: int, dataset: Path) -> None:
    provenance = {
        "source_session": str(session),
        "usable_sidecars": len(shots),
        "aligned_cameras": aligned,
        "total_cameras": total,
        "brush_dataset": str(dataset),
        "metashape_version": Metashape.app.version,
    }
    (out / "metashape_capture_summary.json").write_text(json.dumps(provenance, indent=2, sort_keys=True))
    manifest = session / "manifest.json"
    if manifest.exists():
        shutil.copy2(manifest, out / "source_manifest.json")


def run(args: argparse.Namespace) -> None:
    session = args.session.expanduser().resolve()
    out = args.out.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    shots = load_shots(session)
    print(f"Loaded {len(shots)} usable spatialcam shots from {session}")

    project = out / "project.psx"
    if args.export_only:
        if not project.exists():
            raise SystemExit(f"--export-only requested but {project} does not exist")
        doc = Metashape.Document()
        doc.open(str(project), read_only=False)
        chunk = doc.chunks[0]
    else:
        doc, chunk = make_document(
            session,
            out,
            shots,
            location_accuracy=args.location_accuracy,
            fixed_intrinsics=args.fixed_intrinsics,
            orientation_priors=not args.no_orientation_priors,
            rotation_accuracy=args.rotation_accuracy,
            lens_groups=args.lens_groups,
        )
        align_and_optimize(
            doc,
            chunk,
            downscale=args.downscale,
            keypoint_limit=args.keypoint_limit,
            tiepoint_limit=args.tiepoint_limit,
            fixed_intrinsics=args.fixed_intrinsics,
        )

    aligned = sum(1 for camera in chunk.cameras if camera.transform is not None)
    total = len(chunk.cameras)
    tie_points = len(chunk.tie_points.points) if chunk.tie_points else 0
    dataset = export_brush_dataset(chunk, out)
    doc.save()
    copy_provenance(session, out, shots, aligned, total, dataset)

    print(f"ALIGNED_CAMERAS: {aligned}/{total}")
    print(f"TIE_POINTS: {tie_points}")
    print(f"BRUSH_DATASET: {dataset}")
    print("DONE")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--downscale", type=int, default=1, help="0 Highest, 1 High, 2 Medium.")
    parser.add_argument("--keypoint-limit", type=int, default=40000)
    parser.add_argument("--tiepoint-limit", type=int, default=10000)
    parser.add_argument("--location-accuracy", type=float, default=0.10, help="ARKit position prior accuracy (m).")
    parser.add_argument("--rotation-accuracy", type=float, default=2.0, help="ARKit orientation prior accuracy (deg).")
    parser.add_argument("--no-orientation-priors", action="store_true", help="Disable ARKit rotation priors / 6DoF init (position-only).")
    parser.add_argument("--fixed-intrinsics", action="store_true")
    parser.add_argument("--lens-groups", nargs="?", const=0.05, type=float, default=None,
                        help="Cluster photos into calibration groups by sidecar-v2 lens_position "
                             "(optional bin width, default 0.05) so groups can self-calibrate; "
                             "without this every photo gets its own fixed-by-trust sensor.")
    parser.add_argument("--export-only", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    run(parse_args())
