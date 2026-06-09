import Foundation
import simd

struct SeedPoint {
    let position: simd_float3
    let color: SIMD3<UInt8>
}

final class SeedPointCloud {
    private let voxelSize: Float
    private let maxPoints: Int
    private var voxels: [VoxelKey: SeedPoint] = [:]

    init(voxelSize: Float = 0.03, maxPoints: Int = 500_000) {
        self.voxelSize = voxelSize
        self.maxPoints = maxPoints
    }

    var count: Int { voxels.count }

    func reset() {
        voxels.removeAll(keepingCapacity: true)
    }

    func insert(_ point: simd_float3, color: SIMD3<UInt8> = SIMD3<UInt8>(180, 180, 180)) {
        guard voxels.count < maxPoints else { return }
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        let key = VoxelKey(point: point, voxelSize: voxelSize)
        if voxels[key] == nil {
            voxels[key] = SeedPoint(position: point, color: color)
        }
    }

    func writePLY(to url: URL) throws {
        let points = Array(voxels.values)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let header = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        if let data = header.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }

        for p in points {
            let line = "\(p.position.x) \(p.position.y) \(p.position.z) \(p.color.x) \(p.color.y) \(p.color.z)\n"
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    private struct VoxelKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(point: simd_float3, voxelSize: Float) {
            x = Int(floor(point.x / voxelSize))
            y = Int(floor(point.y / voxelSize))
            z = Int(floor(point.z / voxelSize))
        }
    }
}
