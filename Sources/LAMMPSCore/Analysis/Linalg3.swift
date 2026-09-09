//
//  Linalg3.swift — the 3×3 algebra the strain tools need.
//
//  Deformation-gradient fits (Falk & Langer) need outer products, a matrix
//  product, a transpose and an inverse on 3×3 matrices, per atom, millions of
//  times. Accelerate/LAPACK would dominate the cost in call overhead at this
//  size, so this is the closed-form arithmetic, row-major over `SIMD3`.
//

import Foundation

/// A 3×3 matrix stored as three rows. `M * v` treats `v` as a column vector.
public struct Mat3: Equatable {
    public var r0: SIMD3<Double>
    public var r1: SIMD3<Double>
    public var r2: SIMD3<Double>

    public init(_ r0: SIMD3<Double>, _ r1: SIMD3<Double>, _ r2: SIMD3<Double>) {
        self.r0 = r0; self.r1 = r1; self.r2 = r2
    }

    public static let zero = Mat3(SIMD3(repeating: 0), SIMD3(repeating: 0), SIMD3(repeating: 0))
    public static let identity = Mat3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))

    public subscript(row: Int, col: Int) -> Double {
        get { (row == 0 ? r0 : (row == 1 ? r1 : r2))[col] }
        set {
            switch row {
            case 0: r0[col] = newValue
            case 1: r1[col] = newValue
            default: r2[col] = newValue
            }
        }
    }

    /// Outer product `a bᵀ` — the accumulation term of the affine fit.
    public static func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Mat3 {
        Mat3(b * a.x, b * a.y, b * a.z)
    }

    public static func + (a: Mat3, b: Mat3) -> Mat3 { Mat3(a.r0 + b.r0, a.r1 + b.r1, a.r2 + b.r2) }
    public static func - (a: Mat3, b: Mat3) -> Mat3 { Mat3(a.r0 - b.r0, a.r1 - b.r1, a.r2 - b.r2) }
    public static func += (a: inout Mat3, b: Mat3) { a = a + b }
    public static func * (a: Mat3, s: Double) -> Mat3 { Mat3(a.r0 * s, a.r1 * s, a.r2 * s) }

    /// Matrix × column vector.
    public static func * (m: Mat3, v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((m.r0 * v).sum(), (m.r1 * v).sum(), (m.r2 * v).sum())
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        let bt = b.transposed
        return Mat3(SIMD3((a.r0 * bt.r0).sum(), (a.r0 * bt.r1).sum(), (a.r0 * bt.r2).sum()),
                    SIMD3((a.r1 * bt.r0).sum(), (a.r1 * bt.r1).sum(), (a.r1 * bt.r2).sum()),
                    SIMD3((a.r2 * bt.r0).sum(), (a.r2 * bt.r1).sum(), (a.r2 * bt.r2).sum()))
    }

    public var transposed: Mat3 {
        Mat3(SIMD3(r0.x, r1.x, r2.x), SIMD3(r0.y, r1.y, r2.y), SIMD3(r0.z, r1.z, r2.z))
    }

    public var trace: Double { r0.x + r1.y + r2.z }

    public var determinant: Double {
        r0.x * (r1.y * r2.z - r1.z * r2.y)
      - r0.y * (r1.x * r2.z - r1.z * r2.x)
      + r0.z * (r1.x * r2.y - r1.y * r2.x)
    }

    /// Frobenius norm — the scale the inverse's singularity test is relative to.
    public var frobeniusNorm: Double {
        ((r0 * r0).sum() + (r1 * r1).sum() + (r2 * r2).sum()).squareRoot()
    }

    /// Closed-form inverse; nil when the matrix is singular to within a
    /// relative tolerance (coplanar neighbours make the fit's V singular, and a
    /// numerically "almost" inverse there would be noise, not an answer).
    public var inverse: Mat3? {
        let det = determinant
        let scale = max(frobeniusNorm, .leastNormalMagnitude)
        guard det.isFinite, abs(det) > 1e-10 * scale * scale * scale else { return nil }
        let invDet = 1 / det
        return Mat3(SIMD3(r1.y * r2.z - r1.z * r2.y, r0.z * r2.y - r0.y * r2.z, r0.y * r1.z - r0.z * r1.y) * invDet,
                    SIMD3(r1.z * r2.x - r1.x * r2.z, r0.x * r2.z - r0.z * r2.x, r0.z * r1.x - r0.x * r1.z) * invDet,
                    SIMD3(r1.x * r2.y - r1.y * r2.x, r0.y * r2.x - r0.x * r2.y, r0.x * r1.y - r0.y * r1.x) * invDet)
    }

    /// Green–Lagrangian strain E = ½(FᵀF − I) for `self` = F.
    public var greenLagrangianStrain: Mat3 {
        let ftf = transposed * self
        return (ftf - .identity) * 0.5
    }

    /// Von Mises (deviatoric) invariant of a symmetric tensor — the same
    /// formula serves the strain tensor and the per-atom stress tensor, up to
    /// the factor the caller applies.
    public var vonMisesShear: Double {
        let offDiag = self[0, 1] * self[0, 1] + self[0, 2] * self[0, 2] + self[1, 2] * self[1, 2]
        let dxy = self[0, 0] - self[1, 1], dxz = self[0, 0] - self[2, 2], dyz = self[1, 1] - self[2, 2]
        return (offDiag + (dxy * dxy + dxz * dxz + dyz * dyz) / 6).squareRoot()
    }
}
