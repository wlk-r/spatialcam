import Foundation

enum CaptureTier: String, Codable {
    case lidar = "A_lidar"
    case vioHiRes = "B_vio_hires"
    case vioFallback = "C_vio_fallback"

    var label: String {
        switch self {
        case .lidar: return "LiDAR + ARKit"
        case .vioHiRes: return "High-res ARKit"
        case .vioFallback: return "ARKit tracking"
        }
    }
}

struct DepthRecord: Codable {
    let file: String
    let confidence: String?
    let resolution: [Int]
    let format: String
    let confidenceFormat: String?

    enum CodingKeys: String, CodingKey {
        case file, confidence, resolution, format
        case confidenceFormat = "confidence_format"
    }
}

struct ShotSidecar: Codable {
    let schemaVersion: Int
    let index: Int
    let timestamp: TimeInterval
    let image: String
    let resolution: [Int]
    let intrinsics: [[Float]]
    let transformCameraToWorld: [[Float]]
    let trackingState: String
    let lens: String
    let exposureDuration: Double
    let exposureOffset: Double
    // Sidecar v2: per-shot capture-device state for calibration grouping and
    // photometric normalization downstream. Nil when the device isn't observable (iOS < 16).
    let lensPosition: Float?
    let iso: Float?
    let whiteBalanceGains: [Float]?
    let depth: DepthRecord?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case index, timestamp, image, resolution, intrinsics
        case transformCameraToWorld = "transform_camera_to_world"
        case trackingState = "tracking_state"
        case lens
        case exposureDuration = "exposure_duration"
        case exposureOffset = "exposure_offset"
        case lensPosition = "lens_position"
        case iso
        case whiteBalanceGains = "white_balance_gains"
        case depth
    }
}

struct SessionManifest: Codable {
    let schemaVersion: Int
    let deviceModel: String
    let hasLidar: Bool
    let tier: String
    let systemVersion: String
    let worldAlignment: String
    let lens: String
    let captureCount: Int
    let seedPointCount: Int
    let seedPointCloud: String?
    let depthFormat: String
    let matrixConvention: String
    let arkitToColmapConversionVersion: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case deviceModel = "device_model"
        case hasLidar = "has_lidar"
        case tier
        case systemVersion = "system_version"
        case worldAlignment = "world_alignment"
        case lens
        case captureCount = "capture_count"
        case seedPointCount = "seed_point_count"
        case seedPointCloud = "seed_point_cloud"
        case depthFormat = "depth_format"
        case matrixConvention = "matrix_convention"
        case arkitToColmapConversionVersion = "arkit_to_colmap_conversion_version"
    }
}
