# Data Contract — capture sidecar & manifest (sidecar v2, manifest v1)

The interface between the **iOS capture app** (writer) and the **desktop exporter** (reader).
Changes bump the relevant `schema_version` and the manifest's
`arkit_to_colmap_conversion_version`. Sidecar v2 is a strictly additive change over v1
(three optional capture-device fields); v1 readers can ignore the new keys.

A session is one directory: `session_<ISO8601>/` containing `manifest.json`, a possible
`seed_points.ply`, and per shot `shot_NNNN.jpg` + `shot_NNNN.json` (NNNN zero-padded,
1-indexed, contiguous). LiDAR devices may also write per-shot raw depth and confidence files.

## Conventions (the part that must not drift)

- **All matrices are row-major** in JSON. A 4×4 is `[[r0c0..r0c3], …]`.
- `transform_camera_to_world` is **camera-to-world**, ARKit world convention:
  **+X right, +Y up, −Z forward**, gravity-aligned (so world +Y is up).
- `intrinsics` is the 3×3 `[[fx,0,cx],[0,fy,cy],[0,0,1]]`, **already scaled to `resolution`**
  (the writer rescales ARKit's `imageResolution`-relative intrinsics to the captured image).
- Images are written **unrotated** (native landscape) so they stay consistent with `intrinsics`.
- The **ARKit→COLMAP flip is NOT applied here** — it lives only in the exporter (step 4).
- Focus is **unlocked**, so `intrinsics` drift frame to frame (autofocus). This is intentional —
  the per-frame values are the contract; readers must use them per shot, not assume one shared model.
- **Shots are gated on a settled lens** (sidecar v2 writer): no capture fires while autofocus is
  hunting, so a sidecar's `intrinsics`/`lens_position` always describe a stationary focal length,
  never a mid-transient one. `lens_position` lets readers cluster shots into a few calibration
  groups instead of treating every image as its own camera.

## Writer guarantees

- **Atomic shots.** A shot's sidecar/image/depth are written all-or-nothing (sidecar first); a
  failed write rolls back every file for that index. An image or depth is never left without its
  sidecar.
- **Finite-only.** Frames whose intrinsics/pose/exposure are non-finite (ARKit can emit these right
  after a reset) are dropped *before* claiming an index — they never produce partial files.
- **Contiguity.** Indices are 1-based and strictly contiguous. The v2 writer claims an index only
  after a successful write, so dropped or failed frames consume nothing — no gaps, never an orphan.
  (The v1 writer could leave a clean gap where a frame was dropped.) `audit_session.py` fails on
  orphan files (any `shot_*` with no sidecar) and on index gaps.

## `shot_NNNN.json`

| field | type | meaning |
|-------|------|---------|
| `index` | int | 1-based shot index; matches `NNNN`. |
| `timestamp` | float | ARKit frame timestamp (s). |
| `image` | string | basename of the paired image, e.g. `shot_0001.jpg`. |
| `resolution` | [int,int] | `[width, height]` of the written image. |
| `intrinsics` | float[3][3] | row-major, scaled to `resolution`. |
| `transform_camera_to_world` | float[4][4] | row-major, camera→world, ARKit convention. |
| `tracking_state` | string | always `normal` for committed shots (gate guarantees it). |
| `lens` | string | descriptive lens id for the session. |
| `exposure_duration` | float | seconds; for post photometric normalization. |
| `exposure_offset` | float | EV offset; ditto. |
| `lens_position` | float? | v2. Normalized lens position (0 near … 1 far) at capture; absent when the capture device isn't observable (iOS < 16). Cluster on this for shared calibration groups. |
| `iso` | float? | v2. Sensor ISO at capture; with `exposure_duration`, recovers relative scene radiance for photometric normalization. |
| `white_balance_gains` | float[3]? | v2. Device RGB white-balance gains at capture; lets a reader undo per-shot AWB drift for color-consistent splat training. |
| `depth` | object/null | Optional LiDAR files and format metadata. |

When present, `depth` contains:

| field | type | meaning |
|-------|------|---------|
| `file` | string | Compact row-major Float32 little-endian depth in meters. |
| `confidence` | string? | Optional compact row-major UInt8 confidence map, values 0 low / 1 medium / 2 high. Present only when ARKit provides a confidence map. |
| `resolution` | [int,int] | `[width, height]` for the depth file, and for the confidence file when present. |
| `format` | string | Depth encoding description. |
| `confidence_format` | string? | Confidence encoding description. Present only when `confidence` is present. |

## `manifest.json`

| field | type | meaning |
|-------|------|---------|
| `device_model` | string | e.g. `iPhone15,3`. |
| `has_lidar` | bool | Depth/seed-cloud capture available for this device/session. |
| `tier` | string | `A_lidar` / `B_vio_hires` / `C_vio_fallback`. |
| `system_version` | string | iOS version. |
| `world_alignment` | string | `gravity`. |
| `lens` | string | session lens id. |
| `capture_count` | int | number of shots written. |
| `seed_point_count` | int | number of voxel-downsampled seed points. |
| `seed_point_cloud` | string/null | `seed_points.ply` when a seed cloud was written. |
| `depth_format` | string | Human-readable restatement of optional raw depth encoding. |
| `matrix_convention` | string | human-readable restatement of the rules above. |
| `arkit_to_colmap_conversion_version` | string | Conversion/version marker written by the app or exporter. |

## Mapping to COLMAP (implemented by step 4, stated here so both sides agree)

- One **PINHOLE** camera per image (per-frame intrinsics; autofocus can shift fx/fy).
- `cameras.txt`: `CAMERA_ID PINHOLE width height fx fy cx cy`.
- `images.txt` pose is **world-to-camera** `(QW QX QY QZ TX TY TZ)`, obtained from
  `transform_camera_to_world` by inverting and applying the camera-axis flip `F=diag(1,−1,−1)`.
- **World points stay in ARKit world coords** — only the camera-local frame is flipped.
