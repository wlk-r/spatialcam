import ARKit
import Combine
import CoreImage
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import UIKit

final class CaptureSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var captureCount = 0
    @Published private(set) var seedPointCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var trackingStatus = "not_started"
    @Published private(set) var tier: CaptureTier = .vioFallback
    @Published private(set) var sessionFolderName = "No session"
    @Published private(set) var pendingWriteCount = 0
    @Published private(set) var isFinalizing = false
    @Published private(set) var hasCompletedSession = false

    private let translationThreshold: Float = 0.12
    private let rotationThreshold: Float = .pi / 30
    private let depthSampleStride = 4
    private let lensDescription = "builtInWideAngleCamera"
    private let imageUTType = UTType.jpeg
    private let imageExtension = "jpg"
    private let imageCompressionQuality = 0.92
    private let minimumRecommendedFreeBytes: Int64 = 8 * 1024 * 1024 * 1024

    private weak var session: ARSession?
    private let writeQueue = DispatchQueue(label: "spatialcam.write", qos: .utility)
    private let ciContext = CIContext(options: nil)
    private let seedCloud = SeedPointCloud()

    private var sessionDir: URL?
    private var lastCaptureTransform: simd_float4x4?
    private var isCapturing = false
    private var supportsHiRes = false
    private var supportsDepth = false
    private var nextShotIndex = 1
    private var isSessionPrepared = false
    private var captureRequestID = 0

    func bind(session: ARSession) {
        self.session = session
        session.delegate = self
        DispatchQueue.main.async { [weak self] in
            self?.detectCapabilities()
        }
    }

    func start() {
        guard let session, !isFinalizing else { return }

        detectCapabilities()
        if !isSessionPrepared {
            prepareNewCaptureSession()
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.isAutoFocusEnabled = true

        if #available(iOS 16.0, *),
           let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hiRes
            supportsHiRes = true
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        isCapturing = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func newCapture() {
        guard !isRunning, !isFinalizing else { return }
        prepareNewCaptureSession()
    }

    func storageWarningMessage() -> String? {
        guard let available = availableDiskBytes() else { return nil }
        guard available < minimumRecommendedFreeBytes else { return nil }
        return "Only \(Self.formatBytes(available)) available. Long captures can write several GB. Continue only if this test scan is short."
    }

    func stop() {
        session?.pause()
        isRunning = false
        isSessionPrepared = false
        isFinalizing = true
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeSeedCloud()
            self.writeManifest()
            DispatchQueue.main.async {
                self.isFinalizing = false
                self.hasCompletedSession = true
            }
        }
    }

    private func detectCapabilities() {
        supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if #available(iOS 16.0, *) {
            supportsHiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
        } else {
            supportsHiRes = false
        }

        let detectedTier: CaptureTier
        if supportsDepth {
            detectedTier = .lidar
        } else if supportsHiRes {
            detectedTier = .vioHiRes
        } else {
            detectedTier = .vioFallback
        }

        if Thread.isMainThread {
            tier = detectedTier
        } else {
            DispatchQueue.main.async {
                self.tier = detectedTier
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateTrackingStatus(frame.camera.trackingState)
        guard isRunning, !isCapturing else { return }
        guard case .normal = frame.camera.trackingState else { return }

        if let last = lastCaptureTransform {
            let dPos = simd_distance(frame.camera.transform.translation, last.translation)
            let dRot = geodesicAngle(frame.camera.transform.rotationQuaternion, last.rotationQuaternion)
            guard dPos > translationThreshold || dRot > rotationThreshold else { return }
        }

        lastCaptureTransform = frame.camera.transform
        isCapturing = true
        captureRequestID += 1
        let requestID = captureRequestID
        captureShot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.captureRequestID == requestID && self.isCapturing {
                self.isCapturing = false
            }
        }
    }

    private func captureShot() {
        guard let session else {
            isCapturing = false
            return
        }

        if #available(iOS 16.0, *), supportsHiRes {
            session.captureHighResolutionFrame { [weak self] hiResFrame, _ in
                guard let self else { return }
                if let frame = hiResFrame {
                    self.handle(frame: frame)
                } else if let current = session.currentFrame {
                    self.handle(frame: current)
                } else {
                    DispatchQueue.main.async {
                        self.isCapturing = false
                    }
                }
            }
        } else {
            if let current = session.currentFrame {
                handle(frame: current)
            } else {
                isCapturing = false
            }
        }
    }

    private func handle(frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let intrinsics = scaledIntrinsics(frame.camera.intrinsics,
                                          from: frame.camera.imageResolution,
                                          toWidth: width,
                                          height: height)

        // ARKit can briefly emit non-finite intrinsics/pose/exposure right after (re)start.
        // JSONEncoder throws on those, which would strand a half-written shot, so drop the
        // frame before it claims an index — keeps shot indices contiguous.
        guard intrinsics.isFinite,
              frame.camera.transform.isFinite,
              frame.camera.exposureDuration.isFinite,
              frame.camera.exposureOffset.isFinite else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

        let index = nextShotIndex
        nextShotIndex += 1

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }

        let imageName = String(format: "shot_%04d.%@", index, imageExtension)
        let depthPayload = extractDepthPayload(frame: frame)
        recordSeedGeometry(frame: frame, depthPayload: depthPayload)
        let depthRecord = depthPayload.map { payload in
            DepthRecord(
                file: payload.depthName,
                confidence: payload.confidenceMap == nil ? nil : payload.confidenceName,
                resolution: [payload.width, payload.height],
                format: "float32_little_endian_meters_row_major",
                confidenceFormat: payload.confidenceMap == nil ? nil : "uint8_row_major_0_low_1_medium_2_high"
            )
        }
        let sidecar = ShotSidecar(
            schemaVersion: 1,
            index: index,
            timestamp: frame.timestamp,
            image: imageName,
            resolution: [width, height],
            intrinsics: rowMajor(intrinsics),
            transformCameraToWorld: frame.camera.transform.rowMajorArray(),
            trackingState: string(for: frame.camera.trackingState),
            lens: lensDescription,
            exposureDuration: frame.camera.exposureDuration,
            exposureOffset: Double(frame.camera.exposureOffset),
            depth: depthRecord
        )

        DispatchQueue.main.async {
            self.pendingWriteCount += 1
        }

        writeQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                let didWrite = self.persist(cgImage: cgImage, sidecar: sidecar, depthPayload: depthPayload)
                if didWrite {
                    self.writeManifest()
                }
                DispatchQueue.main.async {
                    self.pendingWriteCount = max(0, self.pendingWriteCount - 1)
                    if didWrite {
                        self.captureCount += 1
                    }
                    self.seedPointCount = self.seedCloud.count
                    self.isCapturing = false
                }
            }
        }
    }

    private func extractDepthPayload(frame: ARFrame) -> DepthPayload? {
        guard let dir = sessionDir,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return nil
        }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let index = nextShotIndex - 1
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthName = String(format: "shot_%04d_depth_f32le.raw", index)
        let confidenceName = String(format: "shot_%04d_conf_u8.raw", index)
        let depthURL = dir.appendingPathComponent(depthName)
        let confidenceURL = dir.appendingPathComponent(confidenceName)

        return DepthPayload(
            depthMap: Self.copyFloatDepth(depthMap),
            confidenceMap: confidenceMap.flatMap(Self.copyConfidence),
            depthURL: depthURL,
            confidenceURL: confidenceURL,
            depthName: depthName,
            confidenceName: confidenceName,
            width: width,
            height: height
        )
    }

    private func recordSeedGeometry(frame: ARFrame, depthPayload: DepthPayload?) {
        if frame.smoothedSceneDepth ?? frame.sceneDepth != nil,
           let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
        accumulateDepthPoints(depthData, camera: frame.camera)
        } else if let featurePoints = frame.rawFeaturePoints {
            for point in featurePoints.points {
                seedCloud.insert(point)
            }
        }
    }

    private func accumulateDepthPoints(_ depthData: ARDepthData, camera: ARCamera) {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let kDepth = scaledIntrinsics(camera.intrinsics,
                                      from: camera.imageResolution,
                                      toWidth: width,
                                      height: height)
        let fx = kDepth.columns.0.x
        let fy = kDepth.columns.1.y
        let cx = kDepth.columns.2.x
        let cy = kDepth.columns.2.y
        let transform = camera.transform

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        for y in stride(from: 0, to: height, by: depthSampleStride) {
            let depthRow = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: depthSampleStride) {
                if let confRow, confRow[x] == 0 { continue }
                let z = depthRow[x]
                guard z.isFinite, z > 0.05, z < 20 else { continue }
                let camX = (Float(x) - cx) / fx * z
                let camY = (Float(y) - cy) / fy * z
                let local = simd_float4(camX, camY, -z, 1)
                let world = transform * local
                seedCloud.insert(simd_float3(world.x, world.y, world.z))
            }
        }
    }

    private func persist(cgImage: CGImage, sidecar: ShotSidecar, depthPayload: DepthPayload?) -> Bool {
        guard let dir = sessionDir else { return false }

        // All-or-nothing: a shot's image/JSON/depth must land together or not at all, otherwise
        // a partial write strands an image (or depth) without its sidecar — the orphan that
        // breaks downstream pairing. On any failure we roll back every file written for this shot.
        var written: [URL] = []
        func rollback() {
            for url in written { try? FileManager.default.removeItem(at: url) }
        }

        // Sidecar first: smallest write and the file downstream keys on.
        let jsonURL = dir.appendingPathComponent(String(format: "shot_%04d.json", sidecar.index))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sidecar),
              (try? data.write(to: jsonURL, options: .atomic)) != nil else {
            return false
        }
        written.append(jsonURL)

        let imageURL = dir.appendingPathComponent(sidecar.image)
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, imageUTType.identifier as CFString, 1, nil) else {
            rollback(); return false
        }
        let options = [kCGImageDestinationLossyCompressionQuality: imageCompressionQuality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            rollback(); return false
        }
        written.append(imageURL)

        if let depthPayload {
            do {
                try depthPayload.depthMap.write(to: depthPayload.depthURL, options: .atomic)
                written.append(depthPayload.depthURL)
                if let confidenceMap = depthPayload.confidenceMap {
                    try confidenceMap.write(to: depthPayload.confidenceURL, options: .atomic)
                    written.append(depthPayload.confidenceURL)
                }
            } catch {
                rollback(); return false
            }
        }

        return true
    }

    private func writeSeedCloud() {
        guard let dir = sessionDir, seedCloud.count > 0 else { return }
        try? seedCloud.writePLY(to: dir.appendingPathComponent("seed_points.ply"))
    }

    private func writeManifest() {
        guard let dir = sessionDir else { return }

        let manifest = SessionManifest(
            schemaVersion: 1,
            deviceModel: UIDevice.current.modelIdentifier,
            hasLidar: supportsDepth,
            tier: tier.rawValue,
            systemVersion: UIDevice.current.systemVersion,
            worldAlignment: "gravity",
            lens: lensDescription,
            captureCount: captureCount,
            seedPointCount: seedCloud.count,
            seedPointCloud: FileManager.default.fileExists(atPath: dir.appendingPathComponent("seed_points.ply").path) ? "seed_points.ply" : nil,
            depthFormat: "optional per-shot Float32 LE meters plus optional UInt8 confidence",
            matrixConvention: "row-major; transform_camera_to_world is camera->world; ARKit axes +X right, +Y up, -Z forward",
            arkitToColmapConversionVersion: "pending-step-4"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    private func prepareSessionDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs.appendingPathComponent("captures/session_\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir
        sessionFolderName = dir.lastPathComponent
    }

    private func availableDiskBytes() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func prepareNewCaptureSession() {
        prepareSessionDirectory()
        seedCloud.reset()
        captureCount = 0
        seedPointCount = 0
        pendingWriteCount = 0
        hasCompletedSession = false
        nextShotIndex = 1
        lastCaptureTransform = nil
        isCapturing = false
        trackingStatus = "not_started"
        isSessionPrepared = true
    }

    private func scaledIntrinsics(_ k: simd_float3x3, from resolution: CGSize, toWidth width: Int, height: Int) -> simd_float3x3 {
        var scaled = k
        let sx = Float(width) / Float(resolution.width)
        let sy = Float(height) / Float(resolution.height)
        scaled.columns.0.x *= sx
        scaled.columns.2.x *= sx
        scaled.columns.1.y *= sy
        scaled.columns.2.y *= sy
        return scaled
    }

    private func updateTrackingStatus(_ state: ARCamera.TrackingState) {
        let status = string(for: state)
        DispatchQueue.main.async {
            self.trackingStatus = status
        }
    }

    private func string(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "limited:initializing"
            case .excessiveMotion:
                return "limited:excessive_motion"
            case .insufficientFeatures:
                return "limited:insufficient_features"
            case .relocalizing:
                return "limited:relocalizing"
            @unknown default:
                return "limited:unknown"
            }
        }
    }

    private static func copyFloatDepth(_ pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data(capacity: width * height * MemoryLayout<Float32>.size)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return data }
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            data.append(UnsafeBufferPointer(start: row, count: width))
        }
        return data
    }

    private static func copyConfidence(_ pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data(capacity: width * height)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return data }
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            data.append(row, count: width)
        }
        return data
    }
}

private struct DepthPayload {
    let depthMap: Data
    let confidenceMap: Data?
    let depthURL: URL
    let confidenceURL: URL
    let depthName: String
    let confidenceName: String
    let width: Int
    let height: Int
}
