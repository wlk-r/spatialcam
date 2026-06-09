import ARKit
import RealityKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Combine
import UIKit

/// Step 2 — pose-only capture loop. VIO poses + per-frame intrinsics on every device.
/// LiDAR depth recording and the seed point cloud are STEP 5; capability is detected
/// here but depth is intentionally not yet recorded. Search "STEP 5" for the seams.
final class CaptureSessionManager: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: Published UI state
    @Published private(set) var captureCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var trackingStatus = "—"
    @Published private(set) var tier: CaptureTier = .vioFallback

    // MARK: Tunables (the accuracy knobs from the plan)
    private let translationThreshold: Float = 0.12          // meters since last shot
    private let rotationThreshold: Float    = .pi / 30      // ~6° since last shot

    // MARK: Internals
    private weak var session: ARSession?                    // owned by the ARView
    private let writeQueue = DispatchQueue(label: "splatcapture.write", qos: .utility)
    private let ciContext  = CIContext(options: nil)
    private let lensDescription = "builtInWideAngleCamera"  // descriptive; ARKit uses the wide camera

    private var sessionDir: URL?
    private var lastCaptureTransform: simd_float4x4?
    private var isCapturing = false
    private var supportsHiRes = false
    private var supportsDepth = false

    // MARK: Binding to the ARView's session
    /// Called from the SwiftUI container once the ARView exists.
    func bind(session: ARSession) {
        self.session = session
        session.delegate = self
    }

    // MARK: Lifecycle
    func start() {
        guard let session else { return }
        detectCapabilities()
        prepareSessionDirectory()

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity        // level floors by construction; no magnetometer jitter
        config.planeDetection = []              // not needed for capture

        if #available(iOS 16.0, *),
           let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hiRes
            supportsHiRes = true
        }

        // STEP 5: when adding depth —
        //   if supportsDepth { config.frameSemantics.insert(.smoothedSceneDepth) }
        // and record frame.smoothedSceneDepth / .sceneDepth + confidence in handle(frame:).

        captureCount = 0
        lastCaptureTransform = nil
        isCapturing = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        session?.pause()
        isRunning = false
        writeManifest()
    }

    private func detectCapabilities() {
        supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if #available(iOS 16.0, *) {
            supportsHiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
        } else {
            supportsHiRes = false
        }
        if supportsDepth        { tier = .lidar }
        else if supportsHiRes   { tier = .vioHiRes }
        else                    { tier = .vioFallback }
    }

    // MARK: Capture loop
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateTrackingStatus(frame.camera.trackingState)
        guard isRunning, !isCapturing else { return }

        // Gate 1 — only capture on healthy tracking.
        guard case .normal = frame.camera.trackingState else { return }

        // Gate 2 — baseline trigger: enough translation OR rotation since the last shot.
        if let last = lastCaptureTransform {
            let dPos = simd_distance(frame.camera.transform.translation, last.translation)
            let dRot = geodesicAngle(frame.camera.transform.rotationQuaternion, last.rotationQuaternion)
            guard dPos > translationThreshold || dRot > rotationThreshold else { return }
        }

        lastCaptureTransform = frame.camera.transform   // commit at trigger to avoid bursts
        isCapturing = true
        captureShot()
    }

    private func captureShot() {
        guard let session else { isCapturing = false; return }
        if #available(iOS 16.0, *), supportsHiRes {
            session.captureHighResolutionFrame { [weak self] hiResFrame, _ in
                guard let self else { return }
                if let f = hiResFrame {
                    self.handle(frame: f)
                } else if let cur = session.currentFrame {
                    self.handle(frame: cur)              // hi-res grab failed → use current
                }
                self.isCapturing = false
            }
        } else {
            if let cur = session.currentFrame { handle(frame: cur) }
            isCapturing = false
        }
    }

    // MARK: Extract + persist
    private func handle(frame: ARFrame) {
        let index = captureCount + 1
        let pixelBuffer = frame.capturedImage
        let bufW = CVPixelBufferGetWidth(pixelBuffer)
        let bufH = CVPixelBufferGetHeight(pixelBuffer)

        // Intrinsics are defined for camera.imageResolution. Rescale to the actual
        // captured buffer (defensive: scale = 1 when they already match).
        var K = frame.camera.intrinsics
        let sx = Float(bufW) / Float(frame.camera.imageResolution.width)
        let sy = Float(bufH) / Float(frame.camera.imageResolution.height)
        K.columns.0.x *= sx   // fx
        K.columns.2.x *= sx   // cx
        K.columns.1.y *= sy   // fy
        K.columns.2.y *= sy   // cy

        // Convert YUV buffer → CGImage now (where the frame is valid), persist bytes later.
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        // NOTE: written in native landscape orientation — matches the intrinsics. Do not rotate.
        let imageName = String(format: "shot_%04d.png", index)
        let sidecar = ShotSidecar(
            index: index,
            timestamp: frame.timestamp,
            image: imageName,
            resolution: [bufW, bufH],
            intrinsics: rowMajor(K),
            transformCameraToWorld: frame.camera.transform.rowMajorArray(),
            trackingState: string(for: frame.camera.trackingState),
            lens: lensDescription,
            exposureDuration: frame.camera.exposureDuration,
            exposureOffset: Double(frame.camera.exposureOffset)
        )

        // STEP 5: also unproject frame.smoothedSceneDepth here (high+med confidence),
        // transform by frame.camera.transform, accumulate into a world-frame seed cloud.

        writeQueue.async { [weak self] in self?.persist(cgImage: cg, sidecar: sidecar) }
        DispatchQueue.main.async { self.captureCount = index }
    }

    private func persist(cgImage: CGImage, sidecar: ShotSidecar) {
        guard let dir = sessionDir else { return }
        let imageURL = dir.appendingPathComponent(sidecar.image)
        if let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }
        let jsonURL = dir.appendingPathComponent(String(format: "shot_%04d.json", sidecar.index))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sidecar) { try? data.write(to: jsonURL) }
    }

    private func writeManifest() {
        guard let dir = sessionDir else { return }
        let manifest = SessionManifest(
            deviceModel: UIDevice.current.modelIdentifier,
            hasLidar: supportsDepth,
            tier: tier.rawValue,
            systemVersion: UIDevice.current.systemVersion,
            worldAlignment: "gravity",
            lens: lensDescription,
            captureCount: captureCount,
            matrixConvention: "row-major; transform_camera_to_world is camera->world; ARKit axes +X right, +Y up, -Z forward",
            arkitToColmapConversionVersion: "pending-step-4"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    // MARK: Helpers
    private func prepareSessionDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs.appendingPathComponent("captures/session_\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir
    }

    private func updateTrackingStatus(_ state: ARCamera.TrackingState) {
        let s = string(for: state)
        DispatchQueue.main.async { self.trackingStatus = s }
    }

    private func string(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing:        return "limited:initializing"
            case .excessiveMotion:     return "limited:excessive_motion"
            case .insufficientFeatures:return "limited:insufficient_features"
            case .relocalizing:        return "limited:relocalizing"
            @unknown default:          return "limited:unknown"
            }
        }
    }
}
