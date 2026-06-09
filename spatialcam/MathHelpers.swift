import Foundation
import simd
import UIKit

extension simd_float4x4 {
    var translation: simd_float3 {
        simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }

    var rotationQuaternion: simd_quatf {
        simd_quatf(simd_float3x3(
            simd_float3(columns.0.x, columns.0.y, columns.0.z),
            simd_float3(columns.1.x, columns.1.y, columns.1.z),
            simd_float3(columns.2.x, columns.2.y, columns.2.z)
        ))
    }

    func rowMajorArray() -> [[Float]] {
        (0..<4).map { r in [columns.0[r], columns.1[r], columns.2[r], columns.3[r]] }
    }
}

func rowMajor(_ m: simd_float3x3) -> [[Float]] {
    (0..<3).map { r in [m.columns.0[r], m.columns.1[r], m.columns.2[r]] }
}

extension simd_float3x3 {
    var isFinite: Bool {
        (0..<3).allSatisfy { c in let col = self[c]; return col.x.isFinite && col.y.isFinite && col.z.isFinite }
    }
}

extension simd_float4x4 {
    var isFinite: Bool {
        (0..<4).allSatisfy { c in let col = self[c]; return col.x.isFinite && col.y.isFinite && col.z.isFinite && col.w.isFinite }
    }
}

func geodesicAngle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
    let d = abs(simd_dot(a.vector, b.vector))
    return 2 * acos(min(1, d))
}

extension UIDevice {
    var modelIdentifier: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            raw.prefix { $0 != 0 }.compactMap { UnicodeScalar(UInt8($0)) }.map(Character.init)
        }.reduce(into: "") { $0.append($1) }
    }
}
