# spatialcam — Step 2/3 Historical Scaffold

Note: this folder is the earlier prototype scaffold. The runnable app target now lives in
`../spatialcam/` with `../spatialcam.xcodeproj`.

A minimal iOS app that records, per shot, a high-res still + ARKit pose + per-frame
intrinsics, throttled by a tracking gate and a movement-based trigger. The production MVP in
`../spatialcam/` now also writes JPG frames, optional LiDAR depth/confidence, and a seed point
cloud. Treat this folder as reference material only.

## What it does
- Detects the capability **tier** (A LiDAR / B VIO+HiRes / C VIO) once at start.
- Runs `ARWorldTrackingConfiguration` with `.gravity` alignment.
- Captures **only** when `trackingState == .normal` and the device has moved
  > ~12 cm **or** rotated > ~6° since the last shot.
- Grabs a 12 MP frame via `captureHighResolutionFrame` (iOS 16+), rescales intrinsics
  to the captured resolution, falls back to `frame.capturedImage` on older devices.
- Writes `shot_NNNN.png` + `shot_NNNN.json` per shot and a `manifest.json` on stop, to
  `Documents/captures/session_<timestamp>/`.

## Xcode setup
1. New iOS App (SwiftUI lifecycle). Delete the generated `ContentView.swift` and
   `…App.swift`, then add the four files in `Sources/`.
2. Build target **iOS 16.0+** (high-res capture API). Run on a **real device** — ARKit
   doesn't work in the simulator.
3. **Info.plist** keys:
   - `NSCameraUsageDescription` → "Capture frames for 3D scanning."
   - `Application supports iTunes file sharing` (`UIFileSharingEnabled`) = `YES`
   - `Supports opening documents in place` (`LSSupportsOpeningDocumentsInPlace`) = `YES`
   The last two expose the session folders in the **Files app** (On My iPhone → 3Dgs Capture)
   so you can AirDrop / copy captures to the desktop for steps 4–6.

## Retrieving captures
Files app → On My iPhone → 3Dgs Capture → `captures/session_<timestamp>/`. Each folder is a
self-contained dataset: images + per-shot JSON + manifest.

## Tunables
In `CaptureSessionManager`:
- `translationThreshold` (default 0.12 m) — lower = denser coverage, more frames.
- `rotationThreshold` (default 6°) — catches look-around motion with little translation.
Start here; tighten for small/detailed rooms, loosen for large open spaces.

## Sidecar contract (what step 4 consumes)
`transform_camera_to_world` — 4×4 **row-major**, ARKit convention (+X right, +Y up, −Z fwd),
**camera-to-world**. `intrinsics` — 3×3 row-major, already scaled to the written image
`resolution`. The ARKit→COLMAP flip belongs in the exporter, **not** here.

## LiDAR depth

The runnable app in `../spatialcam/` has implemented the depth/seed-cloud path. This older scaffold
still documents the earlier planned seams:

1. In `start()`: insert `.smoothedSceneDepth` into `config.frameSemantics` when `supportsDepth`.
2. In `handle(frame:)`: read `frame.smoothedSceneDepth` (depth + confidence), keep
   high+med confidence pixels, unproject with the (scaled) depth intrinsics, transform by
   `frame.camera.transform`, voxel-downsample into a world-frame seed cloud → `points3D`.
3. Add `depth`/`confidence` file refs to `ShotSidecar`.

## Known shape of things (deliberate for MVP)
- ARKit owns the capture session → **auto-exposure** (no hard lock). Exposure is recorded
  per shot for post normalization.
- Images are written **unrotated** (native landscape) to stay consistent with intrinsics.
- The runnable app writes high-quality JPG instead of PNG. PNG writes were too slow and caused
  incomplete long captures during early device tests.
- No re-entrant captures: an `isCapturing` flag blocks overlap while a hi-res grab is pending.
