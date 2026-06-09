# Splat-Capture App — MVP Implementation Plan

Status note, June 2026: this is the original planning document. The runnable implementation now
lives in `spatialcam/`, writes `shot_NNNN.jpg` images plus JSON sidecars, optional raw LiDAR
depth/confidence files, and `seed_points.ply`. The preferred desktop path is the Metashape
workflow documented in `README.md`, `AGENTS.md`, and `docs/Step 4/README.md`.

**Goal:** an iPhone capture app that records, per shot, a high-res still + the camera **pose** and **intrinsics** ARKit already solves for, plus **LiDAR depth when present** — and degrades gracefully to a pose-only capture when it isn't. Output drops straight into the existing `Sharp stills → SfM → PINHOLE COLMAP → Brush → splat-transform` pipeline, with ARKit data turning SfM from the load-bearing step into an optional refinement pass.

The organizing principle: **VIO poses are the asset on every device; LiDAR is a multiplier, never a dependency.** Nothing in the core capture loop branches on LiDAR — only the depth/seed path does.

---

## MVP scope

**In:**
- Capability detection + three-tier graceful degradation.
- Gravity-aligned world tracking, tracking-state-gated capture.
- Baseline-triggered shutter (translation/rotation thresholds), not time-triggered.
- 12 MP high-res frame capture with per-frame intrinsics rescaled to full resolution.
- Single-lens lock per session.
- LiDAR depth + confidence recording and a world-frame seed point cloud; sparse feature-point fallback when no LiDAR.
- Per-shot JSON sidecar + session manifest.
- Desktop exporter: sidecars → COLMAP `cameras/images/points3D.txt` with the coordinate flip handled.

**Out (deferred, see end):** coverage HUD, locked AE/AF/AWB, ProRAW, on-device meshing, cloud upload, multi-session stitching.

---

## 1. Capability detection & the three tiers

Decide tier once at session start; the capture loop is identical across all three.

```swift
let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
let supportsSmoothedDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
let supportsHiRes = !ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing.isNil
```

| Tier | Device class | Poses | Intrinsics | Geometry seed | Notes |
|------|-------------|-------|-----------|---------------|-------|
| **A — LiDAR** | Pro / Pro Max | VIO, depth-assisted | per-frame | dense LiDAR cloud | Best. Reconstructs blank walls; strongest scale lock. |
| **B — VIO only** | non-Pro, modern | VIO | per-frame | sparse `rawFeaturePoints` | Graceful fallback. Poses still excellent; seed is thinner, let Brush densify. |
| **C — no hi-res** | older A-series | VIO | per-frame | feature points | Fall back to `frame.capturedImage` (~1920×1440). Functional, lower detail. |

The fallback is *graceful* precisely because poses + intrinsics — the data SfM is normally fighting to recover — are present in all three tiers. Only the directly-measured geometry degrades, and that's the part SfM/Brush can recover from imagery.

---

## 2. Session configuration (where pose accuracy is won or lost)

```swift
let config = ARWorldTrackingConfiguration()
config.worldAlignment = .gravity            // floors level by construction — feeds your "floors level" SfM check
config.planeDetection = []                   // off; we don't need it, saves compute
config.isAutoFocusEnabled = true             // see note below
if supportsSmoothedDepth      { config.frameSemantics.insert(.smoothedSceneDepth) }
else if supportsDepth         { config.frameSemantics.insert(.sceneDepth) }
config.videoFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing ?? config.videoFormat
```

Three accuracy decisions worth being deliberate about:

- **`.gravity`, not `.gravityAndHeading`.** Heading pulls in the magnetometer, which is noisy indoors near steel/wiring. Gravity alignment alone gives you a level floor (directly serving your top-down verification step) without the heading jitter.
- **Autofocus changes intrinsics.** When AF racks, focal length shifts. ARKit reports intrinsics *per frame*, so this is recorded correctly — but only if you trust the per-frame K and never assume a constant. The alternative (locking focus) trades sharpness on close detail for intrinsic stability; for room-scale capture, leave AF on and rely on per-frame intrinsics. Flag this as a thing to A/B later.
- **Lock one lens per session.** Pin a single `AVCaptureDevice` (e.g. `builtInUltraWideCamera` for tight/low-texture rooms, `builtInWideAngleCamera` for detail) so iOS auto-switching doesn't swap the optical path mid-capture. Per-frame intrinsics *would* track a switch, but a hard lens change also jumps the baseline and confuses matching — cleaner to forbid it.

---

## 3. Capture loop — tracking-gated + baseline-triggered

The single most impactful accuracy choice after using ARKit at all: **don't capture on a timer.** Capture on movement, and only when tracking is healthy.

**Gate 1 — tracking quality.** In `session(_:didUpdate:)`, only consider a frame when:
```swift
guard case .normal = frame.camera.trackingState else { return }  // reject .limited / .notAvailable
```
This alone removes the frames captured during excessive motion, relocalization, or feature starvation — exactly the frames that poison bundle adjustment.

**Gate 2 — baseline trigger.** Fire a high-res capture only after the device has moved enough since the last shot:
```swift
let dPos = simd_distance(frame.camera.transform.translation, lastCapture.translation)
let dRot = angleBetween(frame.camera.transform.rotation, lastCapture.rotation)
guard dPos > 0.12 || dRot > .radians(6) else { return }   // ~12 cm or ~6°
```
This produces uniform spatial/angular sampling, guarantees parallax between consecutive shots, and structurally kills the redundant-frame false-match problem you flagged for look-alike rooms (no parallax change → no new frame).

**Capture — high-res while keeping the pose.** Pull the 12 MP still without losing the frame's pose/intrinsics, and **rescale intrinsics to the captured resolution** (ARKit's `camera.intrinsics` are at video-feed resolution, not the hi-res frame):
```swift
session.captureHighResolutionFrame { hiResFrame, error in
    guard let f = hiResFrame else { return }   // Tier C: fall back to current frame.capturedImage
    let scale = CGFloat(fullWidth) / CGFloat(f.camera.imageResolution.width)
    var K = f.camera.intrinsics
    K[0][0] *= Float(scale); K[1][1] *= Float(scale)   // fx, fy
    K[2][0] *= Float(scale); K[2][1] *= Float(scale)   // cx, cy
    self.write(image: f.capturedImage, pose: f.camera.transform, intrinsics: K, depthFrom: f)
}
```
12 MP HEIC/PNG is the sweet spot. 48 MP ProRAW is slow and overkill for tie-point precision — defer it.

**Loop closure for drift control.** VIO drift is the main enemy of large-scene pose accuracy. Two cheap mitigations: (1) prompt the user to **return to the start and revisit** a few already-covered spots — ARKit's relocalization tightens the global solution when it recognizes prior features; (2) keep walks per continuous session bounded, matching your "per-room standalone solves" rule. The heavy correction happens in post (§6).

---

## 4. LiDAR depth path + fallback

**Tier A (depth present):** each capture records the depth map and confidence map, and accumulates a world-frame seed cloud.
```swift
let depth = frame.smoothedSceneDepth ?? frame.sceneDepth        // CVPixelBuffer Float32, 256×192
let conf  = depth?.confidenceMap                                // 0 low / 1 med / 2 high
```
Build the seed cloud by unprojecting **high+medium confidence** depth pixels with the depth map's own (scaled) intrinsics, transforming by the camera pose into world space, and voxel-downsampling (~2 cm) as you go. This becomes COLMAP `points3D.txt` — the dense seed Brush wants, with metric scale baked in.

**Tier B/C (no depth):** seed from `frame.rawFeaturePoints?.points` — ARKit's sparse tracked world points — accumulated and downsampled across the session. Far sparser than LiDAR, but enough to initialize; let Brush densify from there. If even that's too thin for a given scene, ship no `points3D.txt` and let COLMAP triangulate from matches.

The capture loop never branches on this — depth recording is a side effect keyed off `supportsDepth`. That's what keeps the fallback clean.

---

## 5. Data format

**Per shot** (`shot_0001.json` + `shot_0001.png` + optional `shot_0001_depth.tiff` / `_conf.png`):
```json
{
  "index": 1,
  "timestamp": 12.847,
  "image": "shot_0001.png",
  "resolution": [4032, 3024],
  "intrinsics": [[fx,0,cx],[0,fy,cy],[0,0,1]],
  "transform_camera_to_world": [[...4x4 column-major simd...]],
  "tracking_state": "normal",
  "lens": "builtInWideAngleCamera",
  "exposure_duration": 0.0166,
  "exposure_offset": 0.0,
  "depth": { "file": "shot_0001_depth.tiff", "confidence": "shot_0001_conf.png", "resolution": [256,192] }
}
```
Record `exposure_duration`/`exposure_offset` even though ARKit auto-exposes — it lets you photometrically normalize in post (the price of ARKit owning the capture session; see §8).

**Session manifest** (`manifest.json`): device model, `has_lidar`, tier, ARKit/iOS version, world alignment, lens, capture count, **simd column-major convention note**, and the ARKit→COLMAP conversion version used. Future-you debugging an alignment failure will want every one of these.

---

## 6. Maximizing pose accuracy in post (the actual ceiling)

Recording good poses is half the job; how you consume them is the other half.

- **Don't re-solve poses from scratch.** Feed ARKit poses + intrinsics as *known* and run COLMAP `point_triangulator` (triangulates structure against fixed poses) instead of `mapper` (which re-estimates everything and throws away your priors).
- **Then refine, don't replace.** Run `bundle_adjuster` initialized from ARKit poses to apply global consistency — this is where accumulated VIO drift gets corrected against the global structure. For small scenes the refinement is marginal; for large/looped walks it's the whole game. Best of both: VIO robustness for initialization, BA global accuracy for the final solve.
- **Metashape becomes optional.** With reliable poses + a metric seed cloud, Metashape moves from load-bearing to a verification/refinement option. The PINHOLE export + Brush + splat-transform tail is unchanged.

---

## 7. Desktop exporter + the one gotcha that will bite you

A small Python script converts sidecars → COLMAP text model. The **coordinate-convention flip** is the single highest-risk line in the whole project; everything else can look plausible and still align to garbage if this is wrong.

- **ARKit:** right-handed, +X right, **+Y up**, camera looks down **−Z**; `transform` is **camera-to-world**.
- **COLMAP:** +X right, **+Y down**, camera looks down **+Z**; wants **world-to-camera** `(R|t)`.

The conversion, conceptually:
1. Invert ARKit `transform` → world-to-camera in ARKit's camera frame.
2. Flip the **camera-local** axes by 180° about X (`diag(1,−1,−1)`): negate the Y and Z rows of `R` and of `t`.
3. Emit `R` as a quaternion `(QW QX QY QZ)` and `t` as `(TX TY TZ)` per `images.txt`.
4. **Leave world points unflipped** — the seed cloud stays in ARKit world coordinates. You only changed the camera's *local* convention, not the world frame, so points and cameras remain consistent.

**Validate it, don't trust it.** Pick one shot, unproject a handful of its own high-confidence LiDAR points into the image using the exported COLMAP `(K, R, t)`, and confirm they land where they should. If they're mirrored or upside-down, the flip is wrong — fix it here, once, before it propagates. Pin the conversion version in the manifest so a future change is traceable.

---

## 8. Known tradeoffs to design around

- **ARKit owns the AVCaptureSession → auto-exposure, no hard lock.** You can't get the clean locked AE/AF/AWB a raw AVFoundation pipeline gives. Mitigation: ARKit's AE is smooth (no flicker), and you record exposure per frame for post normalization. If locked exposure were ever non-negotiable you'd go AVFoundation-first — but then you lose poses, and for SfM poses win. Accept the tradeoff for MVP.
- **Rolling shutter** still exists on still capture, but baseline-triggering means you shoot during brief near-stationary moments, minimizing it. Worth a HUD "hold steady" cue later.
- **VIO drift** over long walks — handled by loop-closure prompts (§3) + BA (§6), not by the capture loop.

---

## 9. Build order

1. **Tier detection + session config** (§1–2). Verify gravity alignment and tier reporting on a LiDAR and a non-LiDAR device.
2. **Capture loop** (§3): tracking gate → baseline trigger → high-res grab → intrinsics rescale → write image + sidecar. *No depth yet.* This is a working pose-only capture app on every device — the graceful-fallback path, proven first.
3. **Sidecar + manifest** (§5) solidified.
4. **Desktop exporter + coordinate flip + validation** (§7). Close the loop end-to-end with pose-only data into Brush before touching LiDAR.
5. **LiDAR depth + seed cloud** (§4) layered on as Tier A enhancement.
6. **Post-processing recipe** (§6) wired into the desktop side.

Building the fallback path (steps 1–4) *before* LiDAR is deliberate: it forces the architecture to treat depth as optional from day one, and gives you a shippable app for all devices at step 4.

---

## 10. Acceptance criteria

- Runs and captures on both a LiDAR and a non-LiDAR iPhone; tier logged correctly.
- Every shot has valid `.normal` tracking, a 4×4 pose, and resolution-correct intrinsics.
- Reprojection validation (§7) passes: LiDAR points land correctly in their source image.
- A LiDAR capture produces a posed COLMAP model + seed cloud that Brush trains without a separate SfM solve.
- A non-LiDAR capture produces a posed COLMAP model that aligns and trains (seed from feature points or COLMAP triangulation).

---

## Deferred (post-MVP)
Coverage/connector HUD (RoomPlan-style) · locked AE/AF/AWB experiment · ProRAW/48 MP · reflective-surface masking (Vision/CoreML) · multi-session stitching · on-device QA preview · cloud handoff.
