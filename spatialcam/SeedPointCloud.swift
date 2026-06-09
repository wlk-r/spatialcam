import Foundation
import simd

struct SeedPoint {
    let x: Float
    let y: Float
    let z: Float
    let color: SIMD3<UInt8>
}

final class SeedPointCloud {
    static let defaultColor = SIMD3<UInt8>(180, 180, 180)

    private let voxelSize: Float
    private let maxPoints: Int
    private var voxels: [VoxelKey: SeedPoint] = [:]

    // 1.5 cm voxels with a 3M cap roughly matches Metashape's seed density within
    // LiDAR range (~1.3-2M points room-scale) — the main early-quality lever for
    // Brush per docs/Step 4/arkit_direct_to_brush.md §6. Storage is deliberately
    // compact (12-byte key, 16-byte value, no simd padding) so a full cloud stays
    // around 150-200 MB — fine on the LiDAR-equipped Pro devices this tier runs on.
    init(voxelSize: Float = 0.015, maxPoints: Int = 3_000_000) {
        self.voxelSize = voxelSize
        self.maxPoints = maxPoints
    }

    var count: Int { voxels.count }

    func reset() {
        voxels.removeAll(keepingCapacity: false)
    }

    func insert(_ point: simd_float3, color: SIMD3<UInt8> = SeedPointCloud.defaultColor) {
        guard voxels.count < maxPoints else { return }
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        let key = VoxelKey(point: point, voxelSize: voxelSize)
        if voxels[key] == nil {
            voxels[key] = SeedPoint(x: point.x, y: point.y, z: point.z, color: color)
        }
    }

    func writePLY(to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(voxels.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """

        var bytes = [UInt8]()
        bytes.reserveCapacity(header.utf8.count + voxels.count * 15)
        bytes.append(contentsOf: header.utf8)
        for point in voxels.values {
            Self.appendLittleEndian(point.x, to: &bytes)
            Self.appendLittleEndian(point.y, to: &bytes)
            Self.appendLittleEndian(point.z, to: &bytes)
            bytes.append(point.color.x)
            bytes.append(point.color.y)
            bytes.append(point.color.z)
        }
        try Data(bytes).write(to: url, options: .atomic)
    }

    private static func appendLittleEndian(_ value: Float, to bytes: inout [UInt8]) {
        let bits = value.bitPattern.littleEndian
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
    }

    private struct VoxelKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32

        init(point: simd_float3, voxelSize: Float) {
            x = Int32(floor(point.x / voxelSize))
            y = Int32(floor(point.y / voxelSize))
            z = Int32(floor(point.z / voxelSize))
        }
    }
}
