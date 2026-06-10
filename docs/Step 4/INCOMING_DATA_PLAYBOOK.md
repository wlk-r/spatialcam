# Incoming capture playbook — v2 sessions from testers

What to do when a `session_*.zip` arrives from a TestFlight tester, end to end:
verify → convert → train → review, with every knob and what it trades off.
All scripts live in this folder; python = `.venv/bin/python3` here (numpy + Pillow).

---

## 1. Verify the dump

```bash
unzip -q session_<ts>.zip -d /tmp/incoming/
```

Checklist (a few lines of python or eyeballing):

- `manifest.json` `capture_count` == number of `shot_*.json` == number of `shot_*.jpg`.
- Indices 1..N strictly contiguous (v2 writer guarantees it; a gap means tampering/corruption).
- First sidecar: `schema_version: 2`, `lens_position`/`iso`/`white_balance_gains` present
  (absent = iOS < 16 device; still usable, no lens grouping).
- LiDAR tier: one `*_depth_f32le.raw` + `*_conf_u8.raw` per shot, `has_lidar: true`.
  No depth files = tier B/C device → only the Metashape/COLMAP paths apply (no fusion).
- `seed_points.ply` header says `binary_little_endian`, colors vary (not all 180 180 180).
- All `tracking_state` == `"normal"` (the gate guarantees it; anything else is a red flag).

Capture-quality reads (predicts training quality before spending GPU):

- **Shot spacing**: median Δposition between consecutive shots ~0.12–0.2 m is good;
  p95 > ~0.4 m = tester moved too fast → sparse overlap, expect softness.
- **Exposure**: `exposure_duration` median ≤ ~10 ms good; values ≥ 16 ms while moving = motion blur baked in.
- **Duration vs shots**: ~2 shots/s is the gate's natural rate; far below = lots of standing still.

> **v1 sessions** (pre-2026-06-09, `schema_version: 1`): seed cloud is vertically
> mirrored per camera (Y-sign bug). Add `--no-seed` to the converter and rebuild
> seeds from raw depth with `--fuse-depth`. Poses/images/depth are fine.

## 2. Convert — pick a path

### A. Direct fused (fastest, zero refinement) — baseline

```bash
python3 arkit_to_colmap.py SESSION OUT --fuse-depth
```

| knob | default | when to change |
|---|---|---|
| `--fuse-depth` | off | always on for LiDAR sessions — dense colored init |
| `--fuse-stride N` | 2 | 1 = densest seeds (4x points, slower); 4 = quick previews |
| `--fuse-voxel M` | 0.015 | merge cell size; 0.01 for small/detail scenes, 0.02–0.03 for big spaces |
| `--fuse-max-depth M` | 8.0 | drop to 5–6 if far-range LiDAR noise seeds fuzz |
| `--voxel M` | 0 (off) | global downsample of seed+fused; overrides fuse-voxel as the merge |
| `--no-seed` | off | v1 sessions only (mirrored seed cloud) |
| `--copy` | symlink | use when the dataset will be moved/zipped off-machine |

### B. COLMAP BA + re-fusion (best free quality — "run 4" in the review doc)

```bash
PATH=".venv/bin:$PATH" bash run_colmap.sh SESSION OUT exhaustive
python3 fuse_refined.py SESSION OUT [--stride 2] [--voxel 0.015] [--max-depth 8.0]
# train OUT/brush_dataset_fused
```

- Matcher arg: `exhaustive` (loopy/multi-room scans, ~10 min CPU for ~100 imgs)
  vs `sequential` (single continuous walk, faster).
- Expect bundle_adjuster final cost ≈ 0.6–0.8 px; check camera-extent ratio ≈ 1.00
  before/after (metric scale preserved). `validate.py reproject` runs inside the script.
- Note: feature extraction MUST use `--ImageReader.single_camera_per_image 1`
  (in the script) — EXIF-bearing v2 JPEGs otherwise collapse onto one DB camera.

### C. Metashape (commercial ceiling / comparison)

```bash
./run_metashape_capture.sh SESSION OUT --lens-groups
```

| knob | default | notes |
|---|---|---|
| `--lens-groups [BIN]` | off (bin 0.05) | v2 only: clusters shots into self-calibrating groups by lens_position — use it |
| `--downscale N` | 1 (High) | 0 = Highest (slow), 2 = Medium (quick check) |
| `--location-accuracy M` | 0.10 | ARKit position prior weight; tighter (0.05) trusts VIO more |
| `--rotation-accuracy D` | 2.0 | orientation prior (deg) |
| `--keypoint-limit` / `--tiepoint-limit` | 40000 / 10000 | raise tiepoints (e.g. 20000) for denser seed |
| `--fixed-intrinsics` | off | freeze ARKit intrinsics (no self-calibration); only with per-frame sensors |
| `--no-orientation-priors` | off | position-only priors |

Trains from `OUT/brush_dataset`.

## 3. Train (Brush)

```bash
STEPS=30000 ./run_brush_smoketest.sh DATASET OUT_DIR
```

Script env knobs and their **current values vs Brush defaults** — note the script
UNDER-densifies relative to Brush's own defaults (it was tuned as a smoke test):

| env | script | Brush default | effect |
|---|---|---|---|
| `STEPS` | 30000 | 30000 | — |
| `REFINE_EVERY` | 500 | **200** | lower = denser, tighter splats |
| `GROWTH_STOP` | 12000 | **15000** | longer growth = more splats |
| `MAX_SPLATS` | 4M | **10M** | cap; raise for big scenes |
| `MAX_RESOLUTION` | 1600 | **1920** | higher = sharper gradients, slower |

Quality preset for real (non-smoke) runs:

```bash
STEPS=30000 REFINE_EVERY=200 GROWTH_STOP=15000 MAX_SPLATS=10000000 \
  MAX_RESOLUTION=1920 ./run_brush_smoketest.sh DATASET OUT_DIR
```

Flags the script doesn't expose (pass by editing the script or invoking `brush_app` directly):

| flag | default | use |
|---|---|---|
| `--growth-grad-threshold` | 4e-5 | LOWER = more aggressive densification (try 2e-5 for dense walls) |
| `--growth-select-fraction` | 0.1 | raise to 0.2 to grow more of the flagged splats per refine |
| `--opac-loss-weight` | 1e-9 | penalizes opacity (compaction pressure); set 0 for max solidity |
| `--mean-noise-weight` | 40 | noise on low-opacity splats; helps them relocate or die |
| `--ssim-weight` | 0.2 | structure vs L1 balance |
| `--lpips-loss-weight` | 0 | perceptual loss; can sharpen texture at GPU cost |
| `--eval-split-every N` | off | hold out every Nth image for PSNR — use for honest A/B comparisons |
| `--subsample-points N` | off | quick runs on huge seed clouds |
| `--sh-degree` | 3 | drop to 2 to shrink PLYs if view-dependence isn't needed |

## 4. Transparent / see-through walls — diagnosis order

Observed 2026-06-09: solid, well-covered walls render see-through across all runs.
Check in this order:

1. **Viewpoint (most likely, and not a bug).** Walls are only constrained from
   viewpoints the capture actually had. Viewed from OUTSIDE the scanned volume
   (dollhouse/orbit view), training never penalized transparency along those rays —
   see-through walls from outside are expected 3DGS behavior even in perfect runs.
   Judge solidity only from interior, trajectory-like viewpoints.
2. **Under-densification (the script's conservative knobs).** Too few splats →
   optimizer covers walls with large low-alpha blobs. Fix: quality preset above
   (`REFINE_EVERY=200 GROWTH_STOP=15000 MAX_SPLATS=10M`), then
   `--growth-grad-threshold 2e-5` if still thin.
3. **Opacity pressure.** `--opac-loss-weight 0` removes the (small) built-in push
   toward transparency.
4. **Seed coverage on the wall.** Check the dataset's points3D actually covers the
   wall (LiDAR fusion should). If a wall is glass — no LiDAR return, reflections —
   transparency there is a data limitation, not a training knob.

## 5. Review

Use `REVIEW_2026-06-09_53-53Z.md` criteria: sharpness at 1–2 m, double-edges,
floaters, textureless coverage, color consistency — judged from interior viewpoints.
For quantitative A/Bs, train with `--eval-split-every 8` and compare held-out PSNR
rather than eyeballing.

View PLYs in `/Applications/brush-app-aarch64-apple-darwin/brush_app` (drag the
ply in or pass the path).
