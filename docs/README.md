# 3Dgs Capture

3Dgs Capture is an iPhone capture app for collecting structure-from-motion and Gaussian splat
input data from commodity iPhone hardware. The app records high-resolution stills, ARKit
camera poses, per-frame intrinsics, exposure metadata, LiDAR depth/confidence when available,
and a world-frame seed point cloud.

The current best path is:

1. Capture on a real iPhone with the SwiftUI app in `spatialcam/`.
2. Copy the session directory from Files.app to the Mac.
3. Run the Metashape exporter with tight ARKit reference constraints.
4. Validate camera scale consistency and reprojection quality.
5. Train Brush from the exported COLMAP-style dataset.

## Repository Map

- `spatialcam/` - runnable iOS app source.
- `spatialcam.xcodeproj/` - Xcode project for the iOS app.
- `docs/Step 4/` - desktop validation/export scripts for COLMAP, Metashape, and Brush.
- `docs/Step 2 and 3/` - historical prototype scaffold; keep only for reference.
- `docs/MVP_PLAN.md` - original product/technical plan.
- `AGENTS.md` - senior-dev handoff and project operating notes.

Generated local artifacts such as `device-debug/`, `target/`, Metashape projects, Brush outputs,
and `.xcappdata` bundles should not be committed.

## Build The iOS App

Open `spatialcam.xcodeproj` in Xcode, select the `spatialcam` scheme, choose a real iPhone, and run.
ARKit capture does not work in the Simulator.

The app targets iOS 16+. Camera permission and Files.app sharing are configured in
`spatialcam/Info.plist`.

## Capture Output

Tap `Start`, move slowly through the space, then tap `Stop` before retrieving files. Captures are
written to:

```text
Files app -> On My iPhone -> 3Dgs Capture -> captures/session_<timestamp>/
```

Each session contains:

- `shot_NNNN.jpg` - unrotated high-quality camera image.
- `shot_NNNN.json` - pose, intrinsics, exposure, tracking state, and optional depth references.
- `shot_NNNN_depth_f32le.raw` - optional LiDAR depth as row-major Float32 meters.
- `shot_NNNN_conf_u8.raw` - optional LiDAR confidence as row-major UInt8 values.
- `seed_points.ply` - voxel-downsampled ARKit world-frame seed points.
- `manifest.json` - device/session metadata and coordinate convention notes.

## Current Desktop Pipeline

Use the Metashape path first. It handled the room-transition scale issue better than the pure
COLMAP path when run with tight ARKit camera reference weighting.

```bash
"docs/Step 4/run_metashape_capture.sh" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out \
  --location-accuracy 0.02 \
  --fixed-intrinsics

"docs/Step 4/run_metashape_diagnostics.sh" \
  /path/to/metashape_out/project.psx \
  --blocks "room1:2-57,room2:58-125,room3:126-175"

source "docs/Step 4/.venv/bin/activate"
python "docs/Step 4/validate.py" reproject /path/to/metashape_out/brush_dataset/sparse/0

"docs/Step 4/run_brush_smoketest.sh" \
  /path/to/metashape_out/brush_dataset \
  /path/to/metashape_out/brush_15k \
  15000
```

The `--blocks` ranges are capture-specific. Use shot ranges that correspond to rooms or known
transitions when diagnosing scale drift.

## Known Good Result

For `/Users/walker/Downloads/session_2026-06-08T20-06-12Z`, the tight Metashape run produced:

- `173/174` aligned cameras.
- `319,164` tie points.
- Reprojection median `0.471 px`, p95 `2.219 px`, `0` behind-camera observations.
- Room 3 camera path scale fixed from `0.216x` to `1.000x` relative to ARKit reference.

The corrected output was:

```text
/Users/walker/Downloads/spatialcam_metashape_tight_ref/brush_dataset
```

## Human-In-The-Loop Marker Stage

Only open Metashape for manual markers if diagnostics show a block scale failure after the tight
automatic pass. The pass/fail check should include camera-reference scale, not just reprojection
error.

Use manual markers around the failing transition: door frame corners, trim intersections, outlet
corners, cabinet corners, or floor/wall intersections. Place each marker in several images before
and after the transition, then optimize/export and re-run diagnostics.

## Python Setup

The docs/Step 4 scripts need `numpy` for COLMAP validation/export. Use the local venv:

```bash
python3 -m venv "docs/Step 4/.venv"
source "docs/Step 4/.venv/bin/activate"
python -m pip install -r "docs/Step 4/requirements.txt"
```

Metashape scripts run through Metashape's bundled Python and do not use this venv directly.
