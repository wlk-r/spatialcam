# TestFlight Prep

3Dgs Capture is currently prepared for external TestFlight beta review as a local capture utility.

## App Store Connect

- Bundle ID: `com.walker.spatialcam`
- Version: `0.1`
- Build: increment `CURRENT_PROJECT_VERSION` for each upload.
- Camera permission: captures frames, poses, depth, and camera metadata for 3D scanning.
- Privacy: no tracking, no network upload, no third-party analytics.

## Beta Notes

Use this text for TestFlight test information:

```text
3Dgs Capture is a beta 3D capture utility for testing iPhone/ARKit data capture for structure-from-motion workflows.

What to test:
1. Open the app and grant camera access. The camera preview is live immediately;
   wait for the status to read "Tracking ready".
2. Tap Start.
3. Slowly scan a room or connected spaces. The screen stays awake while recording.
4. Tap Stop and wait until the app reports all files written.
5. Send the capture back: tap the share button next to Start, wait for the zip
   to prepare, then AirDrop it or send an iCloud/Drive link. Sessions can be
   several GB, so AirDrop or a cloud link is usually best.
   - Fallback (e.g. if the phone is low on space): open the Files app >
     On My iPhone > 3Dgs Capture > captures, long-press the session folder >
     Compress, and share the resulting .zip.

The app captures camera images, ARKit camera poses, camera intrinsics, LiDAR depth/confidence data when available, exposure metadata, and a local manifest. Captures are stored locally on device. The app does not upload data, use accounts, or track users.
```

## Upload Flow

1. Open `spatialcam.xcodeproj` in Xcode.
2. Select an Apple Developer team under Signing & Capabilities.
3. Product > Archive.
4. Distribute App > TestFlight & App Store.
5. Upload.
6. In App Store Connect, add the build to an external TestFlight group and submit for beta review.
