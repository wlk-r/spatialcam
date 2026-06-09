# ARKit/LiDAR capture → Brush (no Metashape)

**Status:** validated end-to-end on session `2026-06-09T14-09-57Z` (764 shots, iPhone 14 Pro, LiDAR).
**TL;DR:** Metashape is **not required**. An ARKit capture already contains everything a 3DGS trainer needs, so we can synthesize a COLMAP dataset directly and hand it to Brush — skipping feature matching and bundle adjustment entirely. The main lever for matching Metashape's early quality is **seed-cloud density**, not pose accuracy.

---

## 1. Why Metashape isn't necessary

3DGS training needs exactly three inputs. SfM (Metashape/COLMAP) normally *produces* them; an ARKit+LiDAR capture *already has* them:

| 3DGS needs | From SfM | From our capture |
|---|---|---|
| Camera **intrinsics** | estimated | measured per-shot (`intrinsics` in each `shot_*.json`) |
| Camera **poses** | bundle-adjusted | ARKit VIO `transform_camera_to_world` — metric + gravity-aligned |
| Sparse **init point cloud** | triangulated features | `seed_points.ply` (colored) + LiDAR depth maps |

So there is no structure to *recover* — only a format/convention conversion to perform. This is the step the capture manifest refers to as `arkit_to_colmap_conversion_version: pending-step-4`.

### What each session provides (per shot)
- `shot_NNNN.jpg` — full-res RGB (4032×3024)
- `shot_NNNN.json` — `intrinsics` (3×3), `transform_camera_to_world` (4×4, row-major), `resolution`, `tracking_state`
- `shot_NNNN_depth_f32le.raw` — 256×192 LiDAR depth, float32 metres, row-major
- `shot_NNNN_conf_u8.raw` — 256×192 confidence (0 low / 1 med / 2 high)
- `seed_points.ply` — colored world-space seed cloud (currently 500k points — **see §6**)

---

## 2. The conversion ("Step 4")

Implemented in **[`arkit_to_colmap.py`](./arkit_to_colmap.py)** (alongside this doc in `docs/Step 4/`). Pure-numpy, no Metashape/COLMAP/open3d. (Note: an earlier `arkit_colmap.py`/`export_colmap.py` exist in this folder; reconcile/consolidate as needed.)

### Coordinate conventions — the only real work
- **Direction:** ARKit gives camera→world; COLMAP wants world→camera ⇒ invert.
- **Camera axes:** ARKit cam is `+X right, +Y up, −Z forward`; COLMAP/Brush cam is `+X right, +Y down, +Z forward` ⇒ flip Y and Z with `M = diag(1, −1, −1)`.

```
R_w2c = M · R_c2wᵀ
t_w2c = −R_w2c · t_c2w
```
then convert `R_w2c` to a quaternion `(qw, qx, qy, qz)` for `images.txt`.

The **world frame is unchanged**, so `seed_points.ply` drops straight into `points3D.txt` (just reformat XYZ+RGB). Verified: camera centers round-trip to ~1e-7 m.

### Intrinsics
iPhone autofocus drifts the focal length shot-to-shot (~2996→3021 px across this session), so emit **one COLMAP `PINHOLE` camera per image** with its own `fx fy cx cy` rather than a single shared camera.

### Output layout (standard COLMAP, auto-detected by Brush)
```
out/
  images/              symlinks (or copies) of the JPEGs
  sparse/0/
    cameras.txt        one PINHOLE camera per image
    images.txt         world→camera poses (+ empty POINTS2D line each)
    points3D.txt       seed cloud as id x y z r g b 0
```

### Usage
```bash
python3 arkit_to_colmap.py SESSION_DIR OUT_DIR [--voxel 0.0] [--copy]
# --voxel METERS  optional voxel downsample of the seed cloud (0 = keep all)
# --copy          materialize images instead of symlinking (needed if the
#                 dataset will be moved/zipped away from the session folder)
```

---

## 3. Brush compatibility (verified against source)

- Reads a COLMAP **directory** with `.txt` sparse models.
- Expects the `+X right, +Y down, +Z forward` convention we emit.
- Filename matching is case-insensitive, so `points3D.txt` (capital D) is fine.
- `images/` entries may be symlinks for local training; use `--copy` if relocating.
- **No camera/pose-optimization parameter exists** in the current build (`/Applications/brush-app-aarch64-apple-darwin/brush_app`, Sept 2025). Pose-opt is therefore inherently off — to refine poses you must do it upstream (see §7).

### Smoke-test invocation
```bash
STEPS=20000 ./run_brush_smoketest.sh /path/to/out
# script defaults: GROWTH_STOP=12000, REFINE_EVERY=500, MAX_SPLATS=4000000, MAX_RESOLUTION=1600
```
Note: `brush_app` routes progress to its GUI, not stdout — an empty log is normal. Confirm progress via PLY exports in the output dir (`smoke_{iter}.ply`).

---

## 4. Head-to-head finding (ARKit-direct vs Metashape)

Same 764-image session, both trained in Brush. Snapshots at 5k steps:

| | Seed cloud | Gaussians @ 5k | Growth factor | Point bbox | Camera-center extent |
|---|---|---|---|---|---|
| **ARKit-direct** | 500,000 | 704,041 | **1.41×** | 10×4×9 m | 5.3×1.9×3.7 m |
| **Metashape** | 1,308,789 | 1,794,644 | **1.37×** | 44×9×27 m | 5.3×2.0×3.7 m |

**Interpretation:**
1. **It's the seed density, not the poses.** Both densified by ~1.4× at 5k — identical Brush behavior. The 2.5× Gaussian gap is almost entirely because Metashape started with 2.6× more seed points.
2. **ARKit poses are sound.** Camera-center extents match Metashape's bundle-adjusted result to ~1%, and both are metric. Gross drift would have shown up as a mismatch here; it didn't.
3. **Metashape's one genuine edge is range.** LiDAR depth caps at ~5 m, so the ARKit seed hugs the trajectory (10 m bbox). Metashape triangulates far geometry from imagery (44 m bbox), seeding distant walls/rooms the LiDAR never sees.

Caveat in the comparison: the Metashape run was 30k steps (`brush_30k`) vs our 20k, so at step 5k it was also further into its LR/densification schedule. Not strictly apples-to-apples — compare *final* outputs at matched step counts.

---

## 5. Limitations of the direct path

- **Far-field coverage:** geometry beyond LiDAR range (~5 m) starts with no init points. Brush densifies it from images over time, but slower and thinner than a Metashape seed.
- **No global bundle adjustment:** ARKit VIO is locally accurate but accumulates small drift over long trajectories. Fine for room-scale single loops (confirmed here); large or multi-loop captures may need refinement (§7).

---

## 6. Required change: raise the seed-cloud cap (500k → larger)

> **Update (2026-06-09): implemented.** The app now uses 1.5 cm voxels with a 3M cap and
> samples real colors from the captured image (seeds were flat gray before), and the
> converter grew `--fuse-depth` (conf==2-only LiDAR fusion with JPEG colors). Also fixed:
> the capture app's seed unprojection was missing the Y negation (image v-down vs camera
> Y-up), so **seed clouds from sessions before this date are vertically mirrored per
> camera — rebuild them with `--fuse-depth` rather than trusting `seed_points.ply`**.
> That bug means the 500k-seed numbers in §4's head-to-head undersell the direct path;
> rerun the comparison with a fresh capture. `seed_points.ply` is now binary, not ascii.
> Original analysis kept below.

**The 500k `seed_point_count` is itself an init-density limiter.** The comparison shows Brush's early completeness tracks the seed count almost linearly, and Metashape's advantage at 5k was simply 1.31M seed points vs our 500k. To compete on near-field density without Metashape:

- **Raise `seed_point_count` in the capture/export step to ~1.5–3M** (Metashape's ~1.3M is a sensible floor; the LiDAR mesh easily supports more within range).
- Optionally **fuse the per-shot LiDAR depth maps** into the seed cloud: unproject confident depth pixels (conf == 2) to world via the known poses+intrinsics, voxel-merge, append to `points3D.txt`. This densifies near-field coverage directly and is the cheapest way to match Metashape's 5k-step look. (Hook exists conceptually in the converter; not yet wired up.)
- Far-field (>5 m) still won't be seeded by either approach — accept Brush densifies it, or treat that as the niche where image-based SfM remains useful.

---

## 7. If quality ever looks soft (escalation ladder)

1. **First, raise seed density** (§6) — usually the actual fix, per the finding above.
2. **Refine poses upstream** — this Brush build can't optimize cameras, so to clean up VIO drift seed COLMAP's `point_triangulator` → `bundle_adjuster` *with the ARKit poses + intrinsics as initialization*. Keeps metric scale, globally tightens — the "best of both" without full SfM-from-scratch.
3. **Full SfM (Metashape/COLMAP from scratch)** — last resort; loses metric scale, slowest. The thing this pipeline exists to avoid.

---

## 8. Recommended config (direct ARKit → Brush)

1. Capture with `seed_point_count` ≥ 1.5M (§6).
2. `python3 arkit_to_colmap.py SESSION OUT` (add `--copy` if relocating).
3. `STEPS=30000 ./run_brush_smoketest.sh OUT` for a real run; compare *finals*, not 5k snapshots.
4. Reach for §7 only if soft — start at the top of the ladder.
