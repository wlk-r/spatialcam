# spatialcam Handoff Notes

This repo is a working MVP, not a polished product. Preserve the capture/export contract first;
most downstream failures are coordinate, intrinsics, or scale-consistency mistakes.

## Current State

- The iOS app builds from `spatialcam.xcodeproj` and runs on a real iPhone.
- Captures are JPG plus JSON sidecars, optional LiDAR raw depth/confidence, and `seed_points.ply`.
- The preferred desktop path is Metashape -> COLMAP-format Brush dataset.
- The pure COLMAP path remains in `docs/Step 4/`, but Metashape is currently the best validated route.
- Brush smoke tests have been run successfully from the Metashape export.

## Critical Invariants

- JSON matrices are row-major.
- `transform_camera_to_world` is ARKit camera-to-world.
- ARKit convention is `+X right`, `+Y up`, `-Z forward`, gravity-aligned world.
- Captured images are unrotated native landscape.
- Intrinsics are scaled to the written image resolution.
- Do not apply the ARKit-to-COLMAP camera-axis flip in the iOS app.
- COLMAP conversion applies `F = diag(1, -1, -1)` only to the camera-local frame.
- Metashape `cx`/`cy` are offsets from image center; spatialcam stores absolute pixel principal points.
- Focus is left unlocked; per-frame intrinsics are recorded and passed through. The Metashape
  exporter assigns one calibration group (sensor) per photo, so each frame keeps its own
  fx/fy/cx/cy and the export is one PINHOLE camera per image. Single-image groups cannot
  self-calibrate, so always run with `--fixed-intrinsics`.
- Shots are written atomically by the app: the sidecar is written first and any failure rolls
  back every file for that shot, so an image/depth is never stranded without its JSON. Frames
  with non-finite intrinsics/pose/exposure are dropped before claiming an index. Indices are
  contiguous apart from such drops; `audit_session.py` fails on orphan files or index gaps.

## Recommended End-To-End Workflow

1. Build/run on an iPhone from Xcode.
2. Copy `Files.app -> On My iPhone -> 3Dgs Capture -> captures/session_<timestamp>/` to the Mac.
3. Audit the session:

```bash
source "docs/Step 4/.venv/bin/activate"
python "docs/Step 4/audit_session.py" /path/to/session_<timestamp>
```

4. Run Metashape with strong ARKit reference constraints:

```bash
"docs/Step 4/run_metashape_capture.sh" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out \
  --location-accuracy 0.02 \
  --rotation-accuracy 2.0 \
  --fixed-intrinsics
```

ARKit position + orientation priors are injected by default (`camera.transform` 6DoF init plus
location/rotation references); `--no-orientation-priors` reverts to position-only. On a healthy,
high-overlap scan the orientation priors are effectively a no-op (the image solve is already
tighter than the prior accuracy) — they are insurance against weak-transition collapse, not a
quality gain on good captures. Do not tighten accuracies below ARKit's own noise (~2 cm / ~2°),
or you trade away the more accurate image-based solution.

5. Diagnose camera scale by capture blocks:

```bash
"docs/Step 4/run_metashape_diagnostics.sh" \
  /path/to/metashape_out/project.psx \
  --blocks "room1:2-57,room2:58-125,room3:126-175"
```

6. Validate exported COLMAP reprojection:

```bash
source "docs/Step 4/.venv/bin/activate"
python "docs/Step 4/validate.py" reproject /path/to/metashape_out/brush_dataset/sparse/0
```

7. Run Brush:

```bash
"docs/Step 4/run_brush_smoketest.sh" \
  /path/to/metashape_out/brush_dataset \
  /path/to/metashape_out/brush_15k \
  15000
```

## Quality Gates

Use these as practical gates, not absolute science:

- Aligned cameras: `>95%`.
- Reprojection median: `<1 px`.
- Reprojection p95: preferably `<3 px`.
- Behind-camera observations: `0`.
- Per-block estimated/reference path scale: roughly `0.90-1.10`.
- Per-block median camera-reference delta: low centimeters for room-scale scans.

If reprojection is good but block scale is bad, the solve can still be visually disconnected.
That happened in the first Metashape pass: the third room had low reprojection error but collapsed
to `0.216x` ARKit path scale. Tight references fixed it to `1.000x`.

## Human-In-The-Loop Marker Stage

Only open Metashape for markers after the tight automatic pass fails the block-scale diagnostics.

Open:

```bash
open /path/to/metashape_out/project.psx
```

Add markers on features visible across the weak transition:

- Door frame corners.
- Trim intersections.
- Outlet/switch plate corners.
- Cabinet/counter corners.
- Floor/wall intersections.

Place each marker in multiple images before and after the transition, then run Optimize Cameras,
save, export again with `--export-only`, and re-run diagnostics.

```bash
"docs/Step 4/run_metashape_capture.sh" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out \
  --export-only
```

## Known Gaps

- The app does not yet expose capture density/quality controls in a production UX.
- There is no automated iOS test suite.
- Generated artifacts need to stay out of source control.
- Orientation-prior value is unverified on a *weak* scan. It is implemented and confirmed
  harmless/correct on a healthy scan (reprojection identical to position-only), but the
  weak-transition payoff has not been demonstrated end to end yet.

## Resolved / Landed

- ARKit orientation references **are** now injected into Metashape (6DoF `camera.transform` init
  + location/rotation references, on by default). Rotation is derived via `Metashape.Utils.mat2ypr`
  so the YPR convention is taken from Metashape rather than hand-rolled.
- Per-frame intrinsics flow through (one sensor per photo); the exporter no longer collapses all
  shots onto a single calibration seeded from one frame.
- Orphaned shots are fixed at the source (atomic, sidecar-first writes + non-finite frame guard)
  and made detectable downstream (`audit_session.py` gates orphan files and index gaps).
- The ARKit LiDAR cloud can optionally seed Brush splat initialization via
  `inject_seed_points.py` (a *post-export* step, not a camera-alignment input — the cloud carries
  no camera information independent of the poses that built it, so it cannot constrain alignment).

## Environment Assumptions

- Xcode 26.5 was used for the current local build.
- Metashape Pro 2.3.1 was used for the validated exporter.
- Brush executable was located at `/Applications/brush-app-aarch64-apple-darwin/brush_app`.
- docs/Step 4 local venv lives at `docs/Step 4/.venv`.
