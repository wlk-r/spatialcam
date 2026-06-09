import simd
import Foundation
import UIKit

extension simd_float4x4 {
    /// Translation column of a camera-to-world transform.
    var translation: simd_float3 {
        simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Rotation as a quaternion (upper-left 3x3).
    var rotationQuaternion: simd_quatf {
        simd_quatf(simd_float3x3(
            simd_float3(columns.0.x, columns.0.y, columns.0.z),
            simd_float3(columns.1.x, columns.1.y, columns.1.z),
            simd_float3(columns.2.x, columns.2.y, columns.2.z)
        ))
    }

    /// Row-major [[Float]] for JSON. Inner arrays are rows.
    func rowMajorArray() -> [[Float]] {
        (0..<4).map { r in [columns.0[r], columns.1[r], columns.2[r], columns.3[r]] }
    }
}

/// Row-major [[Float]] for a 3x3 (intrinsics): [[fx,0,cx],[0,fy,cy],[0,0,1]].
func rowMajor(_ m: simd_float3x3) -> [[Float]] {
    (0..<3).map { r in [m.columns.0[r], m.columns.1[r], m.columns.2[r]] }
}

/// Geodesic angle (radians, 0...π) between two orientations — robust vs. quat double-cover.
func geodesicAngle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
    let d = abs(simd_dot(a.vector, b.vector))
    return 2 * acos(min(1, d))
}

extension UIDevice {
    /// e.g. "iPhone15,3" — useful for tying intrinsics/quirks to a physical device later.
    var modelIdentifier: String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            raw.prefix { $0 != 0 }.map { Character(UnicodeScalar(UInt8($0))) }
        }.reduce(into: "") { $0.append($1) }
    }
}
