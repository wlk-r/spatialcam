# spatialcam Next Steps

Current objective: distribute a beta build by TestFlight link/email, not App Store public release.

## Current App State

- Xcode project: `spatialcam.xcodeproj`
- Scheme/target: `spatialcam`
- Bundle ID: `com.walker.spatialcam`
- Display name: `3Dgs Capture`
- Version: `0.1`
- Build: `3`
- App icon: `spatialcam/Assets.xcassets/AppIcon.appiconset`
- Privacy manifest: `spatialcam/PrivacyInfo.xcprivacy`
- Camera permission: `NSCameraUsageDescription` in `spatialcam/Info.plist`
- File sharing: enabled via `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`

The current capture lifecycle is intentionally conservative:

- No AR camera preview before `Start`.
- Capability/tier detection runs on app open.
- `Start` creates a new capture session folder and starts ARKit capture.
- `Stop` pauses ARKit and finalizes image/depth/metadata writes.
- The UI should show `Ready` while idle, not `Starting`.

Do not reintroduce a separate pre-start AR preview right before TestFlight. It caused camera stack churn on iPhone 13 Pro / iOS 26.5 and led to captures stalling after one frame.

## Required Before TestFlight Review

1. In Apple Developer / App Store Connect, create or select an app using bundle ID `com.walker.spatialcam`.
2. In Xcode, confirm Signing & Capabilities uses the active Apple Developer team.
3. Run one clean device test:
   - Delete the existing app from the iPhone.
   - Build/install the current app.
   - Launch and confirm idle state says `Ready`.
   - Tap `Start`, scan enough to capture 20-50 shots.
   - Tap `Stop`, wait for all files to finish writing.
   - Confirm the session folder is visible/exportable through Files/Finder/AirDrop.
4. Archive:
   - Xcode > Product > Archive
   - Distribute App > TestFlight & App Store
   - Upload
5. In App Store Connect TestFlight:
   - Add beta app description.
   - Add feedback email.
   - Add test notes from `TESTFLIGHT.md`.
   - Answer export compliance.
   - Answer App Privacy.
   - Create an external tester group.
   - Add the uploaded build and submit for beta review.

## Suggested TestFlight Notes

Use the longer text in `TESTFLIGHT.md`. Short form:

```text
3Dgs Capture is a beta 3D capture utility for testing iPhone/ARKit data capture for structure-from-motion workflows.

The app captures camera images, ARKit camera poses, camera intrinsics, LiDAR depth/confidence data when available, exposure metadata, and a local manifest. Captures are stored locally on device. The app does not upload data, use accounts, or track users.
```

## App Privacy / Export Compliance

Current expected answers:

- No tracking.
- No third-party analytics.
- No network upload.
- No account system.
- Captured camera/depth/pose data stays local and is user-exported.
- No custom encryption implemented by the app.

## Planned: capture profile toggle (focus / exposure / white balance lock)

The app currently runs fully auto (autofocus, auto exposure, AWB) and instead records the
device state per shot (`lens_position`, `iso`, `white_balance_gains` in sidecar v2) so the
exporter can accommodate drift after the fact. A future capture-profile toggle should offer:

- **Subject (auto)** — today's behavior. Best for mixed near/far scenes and closeups; the
  focus-settled gate already prevents mid-hunt captures.
- **Scene (locked)** — tap-to-focus then `setFocusModeLocked`, plus optional exposure and
  white-balance locks, via `configurableCaptureDeviceForPrimaryCamera`. Best for room-scale
  or constant-distance orbits: one shared calibration group (tighter Metashape/COLMAP BA)
  and view-consistent radiometry for splat training. DoF math: locked at ~2.2 m the f/1.78
  wide camera is sharp roughly 1.6–3.5 m; no lock distance covers both 0.7 m closeups and
  6 m walls, hence the toggle rather than a global lock.

When added: record `focus_mode` / `exposure_mode` / `white_balance_mode` in `manifest.json`,
and have the exporter emit one shared COLMAP camera when focus was locked.

## Known Future Improvement

If instant readiness becomes important, refactor the app state instead of adding preview as a separate mode.

Recommended shape:

- `isSessionRunning`: ARKit is live and updating tracking.
- `isRecording`: captures are being written.
- Start a full capture-compatible ARWorldTrackingConfiguration on app open.
- On `Start`, create a folder, reset counters, and set `isRecording = true`.
- On `Stop`, set `isRecording = false`, finalize files, and optionally keep ARKit running.

This avoids switching AR configurations between preview and recording, but it should be tested carefully on-device before external distribution.

## Verified Locally

Latest local validation:

```bash
plutil -lint spatialcam/Info.plist spatialcam/PrivacyInfo.xcprivacy
xcodebuild -project spatialcam.xcodeproj \
  -scheme spatialcam \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Both passed during the final handoff.
