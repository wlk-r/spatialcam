import Foundation

/// Capability tier decided once at session start. Capture logic keys off the
/// concrete capabilities (`supportsHiRes`, `supportsDepth`) — this label is metadata only.
enum CaptureTier: String, Codable {
    case lidar       = "A_lidar"        // Pro: VIO + LiDAR depth + hi-res
    case vioHiRes    = "B_vio_hires"    // modern non-Pro: VIO + hi-res, sparse seed
    case vioFallback = "C_vio_fallback" // older: VIO only, ~1920x1440 frame

    var label: String {
        switch self {
        case .lidar:       return "A · LiDAR"
        case .vioHiRes:    return "B · VIO+HiRes"
        case .vioFallback: return "C · VIO"
        }
    }
}

/// One capture. Everything the desktop exporter needs to emit a COLMAP camera.
/// Matrices are ROW-MAJOR JSON. `transform_camera_to_world` is in ARKit world
/// convention (+X right, +Y up, −Z forward); the COLMAP flip happens in step 4, not here.
struct ShotSidecar: Codable {
    let index: Int
    let timestamp: TimeInterval
    let image: String
    let resolution: [Int]            // [width, height] of the written image
    let intrinsics: [[Float]]        // 3x3 row-major, scaled to `resolution`
    let transformCameraToWorld: [[Float]]  // 4x4 row-major, camera-to-world
    let trackingState: String
    let lens: String
    let exposureDuration: Double
    let exposureOffset: Double

    enum CodingKeys: String, CodingKey {
        case index, timestamp, image, resolution, intrinsics
        case transformCameraToWorld = "transform_camera_to_world"
        case trackingState          = "tracking_state"
        case lens
        case exposureDuration       = "exposure_duration"
        case exposureOffset         = "exposure_offset"
    }
}

struct SessionManifest: Codable {
    let deviceModel: String
    let hasLidar: Bool
    let tier: String
    let systemVersion: String
    let worldAlignment: String
    let lens: String
    let captureCount: Int
    let matrixConvention: String
    let arkitToColmapConversionVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceModel  = "device_model"
        case hasLidar     = "has_lidar"
        case tier
        case systemVersion = "system_version"
        case worldAlignment = "world_alignment"
        case lens
        case captureCount = "capture_count"
        case matrixConvention = "matrix_convention"
        case arkitToColmapConversionVersion = "arkit_to_colmap_conversion_version"
    }
}
