# Step 4: Desktop Export, Diagnostics, And Brush

This folder converts spatialcam sessions into reconstruction/training inputs. The currently
preferred path is Metashape headless export with ARKit camera references, followed by numeric
diagnostics and Brush training.

## Files

- `audit_session.py` - checks a copied spatialcam session; fails on missing sidecar files, orphan files (a `shot_*` with no sidecar), and index gaps.
- `metashape_capture.py` - spatialcam session -> Metashape project -> Brush-ready COLMAP dataset.
- `inject_seed_points.py` - optional: rewrite the exported `points3D` from the ARKit LiDAR cloud to seed Brush splat init (post-export; not a camera-alignment input).
- `metashape_diagnostics.py` - compares Metashape camera centers against ARKit references.
- `run_metashape_capture.sh` - wrapper for Metashape's bundled Python.
- `run_metashape_diagnostics.sh` - wrapper for diagnostics.
- `run_brush_smoketest.sh` - Brush runner; third positional arg caps total steps.
- `validate.py` - math self-test and COLMAP reprojection validator.
- `arkit_colmap.py`, `export_colmap.py`, `run_colmap.sh` - pure COLMAP path retained for reference.
- `DATA_CONTRACT.md` - writer/reader contract between iOS and desktop.
- `requirements.txt` - `numpy` for local Python scripts.

## Setup

```bash
python3 -m venv "docs/Step 4/.venv"
source "docs/Step 4/.venv/bin/activate"
python -m pip install -r "docs/Step 4/requirements.txt"
```

Metashape scripts run through the installed app, not the venv:

```bash
export METASHAPE=/Applications/MetashapePro.app/Contents/MacOS/MetashapePro
```

Brush defaults to:

```bash
export BRUSH=/Applications/brush-app-aarch64-apple-darwin/brush_app
```

## Recommended Metashape Pipeline

Run the tight automatic pass first:

```bash
"docs/Step 4/run_metashape_capture.sh" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out \
  --location-accuracy 0.02 \
  --rotation-accuracy 2.0 \
  --fixed-intrinsics
```

What those flags do:

- `--location-accuracy 0.02` makes ARKit camera centers a stronger metric reference.
- `--rotation-accuracy 2.0` weights the ARKit orientation priors (degrees). Position **and**
  orientation priors are injected by default (6DoF `camera.transform` init + location/rotation
  references); pass `--no-orientation-priors` for position-only.
- `--fixed-intrinsics` keeps the per-frame spatialcam/ARKit intrinsics from drifting during
  optimization. Required, because one calibration group per photo cannot self-calibrate.

This fixed a room-transition failure where the third room was visually plausible but collapsed to
`0.216x` ARKit path scale. The tight pass produced `1.000x` for that block.

Note: on a healthy, high-overlap scan the orientation priors are effectively a no-op (reprojection
and camera drift are identical to position-only) — they are insurance against weak-transition
collapse, not a quality gain on good captures. Don't tighten accuracies below ARKit's own noise
(~2 cm / ~2°) or you trade away the more accurate image-based solution.

## Optional: seed Brush splats from the ARKit cloud

Brush initializes Gaussians from `points3D`. To start from the dense LiDAR cloud instead of sparse
tie points, run this *after* the Metashape export (in the venv):

```bash
source "docs/Step 4/.venv/bin/activate"
python "docs/Step 4/inject_seed_points.py" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out/brush_dataset
```

It fits a similarity between ARKit and solved camera centers, refuses to inject if the frames
disagree (`--max-residual`), and supports `--mode replace|append`. This is splat initialization
only; it does not affect camera alignment.

## Diagnostics

Run block diagnostics after every Metashape solve:

```bash
"docs/Step 4/run_metashape_diagnostics.sh" \
  /path/to/metashape_out/project.psx \
  --blocks "room1:2-57,room2:58-125,room3:126-175"
```

The block ranges are capture-specific. Use ranges that correspond to rooms, passes, or known
transition points. The script writes `camera_diagnostics.csv` beside the project.

Quality gates:

- Aligned cameras: `>95%`.
- Reprojection median: `<1 px`.
- Reprojection p95: preferably `<3 px`.
- Behind-camera observations: `0`.
- Per-block estimated/reference path scale: roughly `0.90-1.10`.
- Per-block median camera-reference delta: low centimeters for room-scale scans.

Also validate the exported COLMAP model:

```bash
source "docs/Step 4/.venv/bin/activate"
python "docs/Step 4/validate.py" reproject /path/to/metashape_out/brush_dataset/sparse/0
```

## Human Marker Fallback

If the tight automatic solve still has block scale drift or an unmerged transition, open the
Metashape project:

```bash
open /path/to/metashape_out/project.psx
```

Add markers on stable physical features visible on both sides of the transition, such as door
frame corners, trim intersections, outlet corners, cabinet corners, or floor/wall intersections.
Place each marker in several images before and after the break. Then optimize cameras, save, and
re-export:

```bash
"docs/Step 4/run_metashape_capture.sh" \
  /path/to/session_<timestamp> \
  /path/to/metashape_out \
  --export-only
```

Run diagnostics again before training.

## Brush

Train/export checkpoints:

```bash
"docs/Step 4/run_brush_smoketest.sh" \
  /path/to/metashape_out/brush_dataset \
  /path/to/metashape_out/brush_15k \
  15000
```

The script exports `smoke_05000.ply`, `smoke_10000.ply`, and so on every 5000 steps.

Environment overrides:

- `STEPS` or third positional arg - total training steps.
- `GROWTH_STOP` - default `12000`.
- `MAX_SPLATS` - default `4000000`.
- `MAX_RESOLUTION` - default `1600`.

## Pure COLMAP Path

The COLMAP scripts are still useful for comparison and convention testing:

```bash
source "docs/Step 4/.venv/bin/activate"
"docs/Step 4/run_colmap.sh" /path/to/session_<timestamp> /path/to/out sequential
```

Use `exhaustive` instead of `sequential` for loopy or unordered captures.
