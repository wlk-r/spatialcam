import ARKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import UIKit

final class CaptureSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var captureCount = 0
    @Published private(set) var seedPointCount = 0
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var trackingStatus = "not_started"
    @Published private(set) var tier: CaptureTier = .vioFallback
    @Published private(set) var sessionFolderName = "No session"
    @Published private(set) var pendingWriteCount = 0
    @Published private(set) var isFinalizing = false
    @Published private(set) var hasCompletedSession = false
    @Published private(set) var completedSessionURL: URL?
    @Published private(set) var isPreparingShare = false

    private let translationThreshold: Float = 0.12
    private let rotationThreshold: Float = .pi / 30
    private let depthSampleStride = 4
    private let lensDescription = "builtInWideAngleCamera"
    private let imageUTType = UTType.jpeg
    private let imageExtension = "jpg"
    private let imageCompressionQuality = 0.95
    private let minimumRecommendedFreeBytes: Int64 = 8 * 1024 * 1024 * 1024
    // A capture fired mid-autofocus-hunt records a defocused image AND intrinsics sampled
    // during a focal-length transient — the worst of both. Shots wait until the lens has
    // been still for this long.
    private let focusSettleInterval: CFTimeInterval = 0.15
    private let lensPositionEpsilon: Float = 0.005

    private weak var session: ARSession?
    // All capture-session state and file IO are confined to this one serial queue; the
    // capture gate and UI state are confined to main. captureHighResolutionFrame completes
    // on an arbitrary queue, so its result hops to main for validation, then here for work —
    // two concurrent captures can never touch sessionDir/nextShotIndex/seedCloud at once.
    private let sessionQueue = DispatchQueue(label: "spatialcam.session", qos: .utility)
    // Zips must NOT share sessionQueue: a multi-minute archive would block shot
    // processing, and queued shots retain their ARFrames — ARKit stalls the camera
    // once a delegate holds more than a handful. The completed session's files are
    // finished before completedSessionURL publishes, so reading them here is safe
    // while a new session records.
    private let shareQueue = DispatchQueue(label: "spatialcam.share", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    // Backpressure for the capture gate: the 2 s watchdog can reopen the gate while
    // earlier shots are still writing, so bound how many ARFrames may be queued
    // (each retains a full hi-res capture, and ARKit stops the camera past ~a dozen).
    private let maxPendingWrites = 3

    // sessionQueue-confined
    private let seedCloud = SeedPointCloud()
    private var sessionDir: URL?
    private var nextShotIndex = 1
    private var writtenCount = 0
    private var isAcceptingShots = false
    private var manifestContext: ManifestContext?

    // main-confined
    private var lastCaptureTransform: simd_float4x4?
    private var isCapturing = false
    private var supportsHiRes = false
    private var supportsDepth = false
    private var isSessionPrepared = false
    private var captureRequestID = 0
    private var captureDevice: AVCaptureDevice?
    private var deviceObservers: [NSKeyValueObservation] = []
    private var isAdjustingFocus = false
    private var currentLensPosition: Float?
    private var lastLensMoveTime: CFTimeInterval = 0

    func bind(session: ARSession) {
        self.session = session
        session.delegate = self
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectCapabilities()
            self.runSession()
        }
    }

    // The session runs continuously from app open with the one capture-capable
    // configuration; Start/Stop only toggle the recording gate. Recording therefore
    // begins on already-converged VIO (no warm-up wobble in the first shots), and no
    // configuration switch ever touches the camera stack — the churn that stalled
    // captures on iPhone 13 Pro / iOS 26.5.
    private func runSession() {
        guard let session else { return }

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

        // No reset options: tracking stays converged across recordings. The world
        // origin is wherever the session began, which the data contract permits —
        // each session's poses are self-consistent and gravity-aligned.
        session.run(config)
        attachCaptureDevice()
        isSessionRunning = true
    }

    func start() {
        guard session != nil, !isFinalizing, !isRecording, !isPreparingShare else { return }
        if !isSessionRunning {
            runSession()
        }
        if !isSessionPrepared {
            prepareNewCaptureSession()
        }
        isCapturing = false
        isRecording = true
        // A scan runs for minutes without touches; don't let the screen lock mid-capture.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func newCapture() {
        guard !isRecording, !isFinalizing, !isPreparingShare else { return }
        prepareNewCaptureSession()
    }

    func storageWarningMessage() -> String? {
        guard let available = availableDiskBytes() else { return nil }
        guard available < minimumRecommendedFreeBytes else { return nil }
        return "Only \(Self.formatBytes(available)) available. Long captures can write several GB. Continue only if this test scan is short."
    }

    func stop() {
        // The session keeps running — only the recording gate closes, so the next
        // recording starts instantly on still-converged tracking.
        captureRequestID += 1
        isCapturing = false
        isRecording = false
        isSessionPrepared = false
        isFinalizing = true
        UIApplication.shared.isIdleTimerDisabled = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isAcceptingShots = false
            self.writeSeedCloud()
            self.writeManifest()
            let dir = self.sessionDir
            DispatchQueue.main.async {
                self.isFinalizing = false
                self.hasCompletedSession = true
                self.completedSessionURL = dir
            }
        }
    }

    // MARK: - Share

    enum ShareArchiveError: LocalizedError {
        case insufficientSpace(needed: Int64, available: Int64)
        case archiveFailed

        var errorDescription: String? {
            switch self {
            case .insufficientSpace(let needed, let available):
                return "Not enough free space to create a zip (needs about \(CaptureSessionManager.formatBytes(needed)), \(CaptureSessionManager.formatBytes(available)) available). Share the session folder directly from the Files app instead: On My iPhone > 3Dgs Capture > captures."
            case .archiveFailed:
                return "Could not create the zip archive. Share the session folder directly from the Files app instead: On My iPhone > 3Dgs Capture > captures."
            }
        }
    }

    func prepareShareArchive(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let sessionURL = completedSessionURL, !isPreparingShare else { return }
        isPreparingShare = true
        // A multi-GB zip takes minutes with no touches; a screen lock would suspend
        // the app and stall it mid-archive.
        UIApplication.shared.isIdleTimerDisabled = true
        shareQueue.async { [weak self] in
            guard let self else { return }
            let finish: (Result<URL, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    self.isPreparingShare = false
                    UIApplication.shared.isIdleTimerDisabled = self.isRecording
                    completion(result)
                }
            }

            // The zip is roughly session-sized (JPEGs don't recompress), and if the
            // move below falls back to a copy, the coordinator's zip and ours coexist
            // briefly — so demand 2x the session plus headroom.
            let sessionSize = Self.directorySize(of: sessionURL)
            if let available = self.availableDiskBytes(), available < sessionSize * 2 + 200 * 1024 * 1024 {
                finish(.failure(ShareArchiveError.insufficientSpace(needed: sessionSize * 2, available: available)))
                return
            }

            // .forUploading hands back a zipped copy of the directory — the system's
            // own folder-zipping path, no archive library needed. The zip only lives
            // for the block, so move (or copy) it out to temp before returning.
            var coordinatorError: NSError?
            var result: Result<URL, Error> = .failure(ShareArchiveError.archiveFailed)
            NSFileCoordinator().coordinate(readingItemAt: sessionURL, options: [.forUploading], error: &coordinatorError) { zipped in
                do {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(sessionURL.lastPathComponent)
                        .appendingPathExtension("zip")
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        // Move avoids a second multi-GB write (and the 2x disk peak).
                        try FileManager.default.moveItem(at: zipped, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: zipped, to: destination)
                    }
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinatorError {
                result = .failure(coordinatorError)
            }
            finish(result)
        }
    }

    static func capturesFolderFilesURL() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("captures").path
        return URL(string: "shareddocuments://" + path)
    }

    private static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
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

    // MARK: - Focus observation

    private func attachCaptureDevice() {
        guard #available(iOS 16.0, *), captureDevice == nil,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        captureDevice = device
        // KVO fires on arbitrary threads; mirror onto main where the capture gate reads.
        deviceObservers = [
            device.observe(\.isAdjustingFocus, options: [.initial, .new]) { [weak self] _, change in
                guard let adjusting = change.newValue else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isAdjustingFocus != adjusting {
                        self.lastLensMoveTime = CACurrentMediaTime()
                    }
                    self.isAdjustingFocus = adjusting
                }
            },
            device.observe(\.lensPosition, options: [.initial, .new]) { [weak self] _, change in
                guard let position = change.newValue else { return }
                DispatchQueue.main.async {
                    self?.registerLensPosition(position)
                }
            }
        ]
    }

    private func registerLensPosition(_ position: Float) {
        if currentLensPosition.map({ abs(position - $0) > lensPositionEpsilon }) ?? true {
            lastLensMoveTime = CACurrentMediaTime()
        }
        currentLensPosition = position
    }

    private var isFocusSettled: Bool {
        // No observable device (iOS < 16): don't gate, behave as before.
        guard captureDevice != nil else { return true }
        if isAdjustingFocus { return false }
        return CACurrentMediaTime() - lastLensMoveTime > focusSettleInterval
    }

    private func sampleCaptureDevice() -> DeviceSample {
        guard let device = captureDevice else {
            return DeviceSample(lensPosition: nil, iso: nil, whiteBalanceGains: nil)
        }
        let gains = device.deviceWhiteBalanceGains
        return DeviceSample(
            lensPosition: device.lensPosition,
            iso: device.iso,
            whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain]
        )
    }

    // MARK: - Session observation

    // The always-on session lives across phone calls, app switches, and camera
    // contention, so interruptions and failures must be handled here rather than
    // by the user pressing Start again.

    func sessionWasInterrupted(_ session: ARSession) {
        // No frames arrive while interrupted, so this status persists until ARKit
        // resumes and the next didUpdate overwrites it.
        DispatchQueue.main.async {
            self.trackingStatus = "interrupted"
        }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // Keep the world frame across interruptions so an in-progress recording's
        // poses stay in one consistent coordinate system.
        true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSessionRunning = false
            self.trackingStatus = "failed"
            // e.g. camera became unavailable; retry once the system settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.isSessionRunning else { return }
                self.runSession()
            }
        }
    }

    // MARK: - Capture gate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateTrackingStatus(frame.camera.trackingState)
        guard isRecording, !isCapturing else { return }
        guard pendingWriteCount < maxPendingWrites else { return }
        guard case .normal = frame.camera.trackingState else { return }
        guard isFocusSettled else { return }

        if let last = lastCaptureTransform {
            let dPos = simd_distance(frame.camera.transform.translation, last.translation)
            let dRot = geodesicAngle(frame.camera.transform.rotationQuaternion, last.rotationQuaternion)
            guard dPos > translationThreshold || dRot > rotationThreshold else { return }
        }

        lastCaptureTransform = frame.camera.transform
        isCapturing = true
        captureRequestID += 1
        let requestID = captureRequestID
        captureShot(requestID: requestID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.captureRequestID == requestID && self.isCapturing {
                self.isCapturing = false
            }
        }
    }

    private func captureShot(requestID: Int) {
        guard let session else {
            isCapturing = false
            return
        }

        if #available(iOS 16.0, *), supportsHiRes {
            session.captureHighResolutionFrame { [weak self] hiResFrame, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Drop the result if a stop, new session, or the watchdog moved on.
                    guard requestID == self.captureRequestID, self.isCapturing else { return }
                    if let frame = hiResFrame ?? session.currentFrame {
                        self.enqueue(frame: frame)
                    } else {
                        self.isCapturing = false
                    }
                }
            }
        } else if let current = session.currentFrame {
            enqueue(frame: current)
        } else {
            isCapturing = false
        }
    }

    private func enqueue(frame: ARFrame) {
        pendingWriteCount += 1
        let deviceSample = sampleCaptureDevice()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.process(frame: frame, deviceSample: deviceSample)
            }
        }
    }

    // MARK: - Shot processing (sessionQueue)

    private func process(frame: ARFrame, deviceSample: DeviceSample) {
        defer {
            let written = writtenCount
            let seeds = seedCloud.count
            DispatchQueue.main.async {
                self.pendingWriteCount = max(0, self.pendingWriteCount - 1)
                self.captureCount = written
                self.seedPointCount = seeds
                self.isCapturing = false
            }
        }

        guard isAcceptingShots, let dir = sessionDir else { return }

        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let intrinsics = scaledIntrinsics(frame.camera.intrinsics,
                                          from: frame.camera.imageResolution,
                                          toWidth: width,
                                          height: height)

        // ARKit can briefly emit non-finite intrinsics/pose/exposure right after (re)start.
        // JSONEncoder throws on those. An index is only claimed after a successful write,
        // so dropped frames cost nothing and shot indices stay strictly contiguous.
        guard intrinsics.isFinite,
              frame.camera.transform.isFinite,
              frame.camera.exposureDuration.isFinite,
              frame.camera.exposureOffset.isFinite else {
            return
        }

        let index = nextShotIndex

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let imageName = String(format: "shot_%04d.%@", index, imageExtension)
        let depthPayload = extractDepthPayload(frame: frame, index: index, dir: dir)
        recordSeedGeometry(frame: frame)
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
            schemaVersion: 2,
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
            lensPosition: deviceSample.lensPosition,
            iso: deviceSample.iso,
            whiteBalanceGains: deviceSample.whiteBalanceGains,
            depth: depthRecord
        )

        if persist(cgImage: cgImage, sidecar: sidecar, depthPayload: depthPayload, dir: dir) {
            nextShotIndex += 1
            writtenCount += 1
            writeManifest()
        }
    }

    private func extractDepthPayload(frame: ARFrame, index: Int, dir: URL) -> DepthPayload? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return nil
        }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthName = String(format: "shot_%04d_depth_f32le.raw", index)
        let confidenceName = String(format: "shot_%04d_conf_u8.raw", index)

        return DepthPayload(
            depthMap: Self.copyFloatDepth(depthMap),
            confidenceMap: confidenceMap.flatMap(Self.copyConfidence),
            depthURL: dir.appendingPathComponent(depthName),
            confidenceURL: dir.appendingPathComponent(confidenceName),
            depthName: depthName,
            confidenceName: confidenceName,
            width: width,
            height: height
        )
    }

    // MARK: - Seed cloud (sessionQueue)

    private func recordSeedGeometry(frame: ARFrame) {
        // Sampler locks the captured image for the duration of seed accumulation and
        // unlocks in deinit; colors feed Brush's splat init (SH DC term).
        let sampler = YCbCrSampler(pixelBuffer: frame.capturedImage)
        if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
            accumulateDepthPoints(depthData, camera: frame.camera, sampler: sampler)
        } else if let featurePoints = frame.rawFeaturePoints {
            accumulateFeaturePoints(featurePoints.points, camera: frame.camera, sampler: sampler)
        }
    }

    private func accumulateDepthPoints(_ depthData: ARDepthData, camera: ARCamera, sampler: YCbCrSampler?) {
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
        // Depth map and captured image share the same FOV/aspect, so colors map linearly.
        let imageScaleX = sampler.map { Float($0.width) / Float(width) }
        let imageScaleY = sampler.map { Float($0.height) / Float(height) }

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
                // Image v points down while ARKit camera +Y points up, so the pinhole
                // lift is (x', -y', -z) — Apple's scene-depth sample applies the same
                // flipYZ. Omitting the Y negation mirrors seeds about each optical axis.
                let camX = (Float(x) - cx) / fx * z
                let camY = -(Float(y) - cy) / fy * z
                let local = simd_float4(camX, camY, -z, 1)
                let world = transform * local

                var color = SeedPointCloud.defaultColor
                if let sampler, let sx = imageScaleX, let sy = imageScaleY {
                    let imgX = min(sampler.width - 1, Int((Float(x) + 0.5) * sx))
                    let imgY = min(sampler.height - 1, Int((Float(y) + 0.5) * sy))
                    if let sampled = sampler.color(atX: imgX, y: imgY) {
                        color = sampled
                    }
                }
                seedCloud.insert(simd_float3(world.x, world.y, world.z), color: color)
            }
        }
    }

    private func accumulateFeaturePoints(_ points: [simd_float3], camera: ARCamera, sampler: YCbCrSampler?) {
        guard let sampler else {
            for point in points { seedCloud.insert(point) }
            return
        }
        let worldToCamera = simd_inverse(camera.transform)
        let k = scaledIntrinsics(camera.intrinsics,
                                 from: camera.imageResolution,
                                 toWidth: sampler.width,
                                 height: sampler.height)
        let fx = k.columns.0.x
        let fy = k.columns.1.y
        let cx = k.columns.2.x
        let cy = k.columns.2.y

        for point in points {
            let cam = worldToCamera * simd_float4(point, 1)
            // ARKit camera looks down -Z; image y axis points down while camera +Y is up.
            let zForward = -cam.z
            var color = SeedPointCloud.defaultColor
            if zForward > 0.05 {
                let u = Int((fx * cam.x / zForward + cx).rounded())
                let v = Int((fy * -cam.y / zForward + cy).rounded())
                if let sampled = sampler.color(atX: u, y: v) {
                    color = sampled
                }
            }
            seedCloud.insert(point, color: color)
        }
    }

    // MARK: - Persistence (sessionQueue)

    private func persist(cgImage: CGImage, sidecar: ShotSidecar, depthPayload: DepthPayload?, dir: URL) -> Bool {
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
        CGImageDestinationAddImage(destination, cgImage, imageProperties(for: sidecar))
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

    // EXIF/TIFF for the Metashape path: it auto-builds calibration groups from
    // (Make, Model, 35mm focal, resolution), so embedding these lets it initialize
    // sensible groups without manual calibration import. The 35mm focal is rounded
    // to an integer so autofocus drift doesn't shatter shots into per-image groups.
    private func imageProperties(for sidecar: ShotSidecar) -> CFDictionary {
        var exif: [CFString: Any] = [
            kCGImagePropertyExifExposureTime: sidecar.exposureDuration,
            kCGImagePropertyExifLensModel: sidecar.lens,
            kCGImagePropertyExifDateTimeOriginal: Self.exifDateFormatter.string(from: Date())
        ]
        let fx = sidecar.intrinsics[0][0]
        let w = Float(sidecar.resolution[0])
        let h = Float(sidecar.resolution[1])
        let diagonal = (w * w + h * h).squareRoot()
        if diagonal > 0, fx.isFinite {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = Int((fx * 43.266615 / diagonal).rounded())
        }
        if let iso = sidecar.iso {
            exif[kCGImagePropertyExifISOSpeedRatings] = [Int(iso.rounded())]
        }

        var tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Apple"]
        if let model = manifestContext?.deviceModel {
            tiff[kCGImagePropertyTIFFModel] = model
        }

        return [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImageDestinationLossyCompressionQuality: imageCompressionQuality
        ] as CFDictionary
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private func writeSeedCloud() {
        guard let dir = sessionDir, seedCloud.count > 0 else { return }
        try? seedCloud.writePLY(to: dir.appendingPathComponent("seed_points.ply"))
    }

    private func writeManifest() {
        guard let dir = sessionDir, let context = manifestContext else { return }

        let manifest = SessionManifest(
            schemaVersion: 1,
            deviceModel: context.deviceModel,
            hasLidar: context.hasLidar,
            tier: context.tier,
            systemVersion: context.systemVersion,
            worldAlignment: "gravity",
            lens: lensDescription,
            captureCount: writtenCount,
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

    // MARK: - Session lifecycle

    private func prepareNewCaptureSession() {
        // Snapshot manifest inputs on main; sessionQueue must not touch UIDevice or @Published.
        let context = ManifestContext(
            deviceModel: UIDevice.current.modelIdentifier,
            hasLidar: supportsDepth,
            tier: tier.rawValue,
            systemVersion: UIDevice.current.systemVersion
        )
        captureCount = 0
        seedPointCount = 0
        pendingWriteCount = 0
        hasCompletedSession = false
        completedSessionURL = nil
        lastCaptureTransform = nil
        isCapturing = false
        isSessionPrepared = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let dir = self.createSessionDirectory()
            self.sessionDir = dir
            self.seedCloud.reset()
            self.nextShotIndex = 1
            self.writtenCount = 0
            self.manifestContext = context
            self.isAcceptingShots = dir != nil
            DispatchQueue.main.async {
                self.sessionFolderName = dir?.lastPathComponent ?? "No session"
            }
        }
    }

    private func createSessionDirectory() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs.appendingPathComponent("captures/session_\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    private func availableDiskBytes() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

private struct DeviceSample {
    let lensPosition: Float?
    let iso: Float?
    let whiteBalanceGains: [Float]?
}

private struct ManifestContext {
    let deviceModel: String
    let hasLidar: Bool
    let tier: String
    let systemVersion: String
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

/// Read-only color sampler over ARKit's bi-planar YCbCr captured image.
/// Locks the buffer's base addresses for its lifetime; unlocks in deinit.
private final class YCbCrSampler {
    private let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    private let lumaBase: UnsafeRawPointer
    private let lumaStride: Int
    private let chromaBase: UnsafeRawPointer
    private let chromaStride: Int
    private let isVideoRange: Bool

    init?(pixelBuffer: CVPixelBuffer) {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            isVideoRange = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            isVideoRange = true
        default:
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return nil
        }

        self.pixelBuffer = pixelBuffer
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        lumaBase = UnsafeRawPointer(luma)
        lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        chromaBase = UnsafeRawPointer(chroma)
        chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    func color(atX x: Int, y: Int) -> SIMD3<UInt8>? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let rawY = Float(lumaBase.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)[x])
        let chromaRow = chromaBase.advanced(by: (y / 2) * chromaStride).assumingMemoryBound(to: UInt8.self)
        let cbIndex = (x / 2) * 2
        let rawCb = Float(chromaRow[cbIndex])
        let rawCr = Float(chromaRow[cbIndex + 1])

        // BT.709 YCbCr -> RGB (expand video range first when needed).
        let yv = isVideoRange ? (rawY - 16) * (255.0 / 219.0) : rawY
        let chromaScale: Float = isVideoRange ? 255.0 / 224.0 : 1
        let cb = (rawCb - 128) * chromaScale
        let cr = (rawCr - 128) * chromaScale
        let r = yv + 1.5748 * cr
        let g = yv - 0.1873 * cb - 0.4681 * cr
        let b = yv + 1.8556 * cb
        return SIMD3<UInt8>(
            UInt8(clamping: Int(r.rounded())),
            UInt8(clamping: Int(g.rounded())),
            UInt8(clamping: Int(b.rounded()))
        )
    }
}
