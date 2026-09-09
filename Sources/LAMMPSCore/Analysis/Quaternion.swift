//
//  Quaternion.swift — unit quaternions, Horn's absolute orientation, and the
//  crystal symmetry groups the grain analysis reduces orientations by.
//
//  Polyhedral template matching needs, per atom and per candidate template, the
//  rotation that best maps an ideal neighbour shell onto the measured one. The
//  textbook answer is Kabsch via SVD; Horn (1987, J. Opt. Soc. Am. A 4, 629)
//  gives the same rotation as the eigenvector of a 4×4 symmetric matrix, which
//  needs no SVD at all — a cyclic Jacobi sweep on 4×4 is twenty lines and is
//  exact enough that a perfect lattice returns RMSD 0 to machine precision.
//
//  Orientations only mean something modulo the lattice's own rotations: two
//  fcc grains related by a 90° turn about a cube axis are the same grain. The
//  disorientation below reduces by the proper rotation group of the lattice.
//

import Foundation

/// A quaternion (w, x, y, z) with w the scalar part. Unit quaternions here are
/// rotations; `rotate` uses the usual q v q⁻¹ convention.
public struct Quat: Equatable {
    public var w: Double, x: Double, y: Double, z: Double

    public init(_ w: Double, _ x: Double, _ y: Double, _ z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quat(1, 0, 0, 0)

    public var conjugate: Quat { Quat(w, -x, -y, -z) }
    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public func normalized() -> Quat {
        let n = norm
        guard n > 1e-300 else { return .identity }
        return Quat(w / n, x / n, y / n, z / n)
    }

    /// Rotation angle in radians (0…π); the double cover means ±q are the same
    /// rotation, hence the absolute value.
    public var angle: Double { 2 * acos(Swift.min(1, abs(w))) }

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    /// The scalar part of `a * b`, without forming the product — the only part
    /// the disorientation search needs, and it makes that search 24 dot
    /// products instead of 24 quaternion multiplications.
    public static func scalarOfProduct(_ a: Quat, _ b: Quat) -> Double {
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    }

    public static func axisAngle(axis: SIMD3<Double>, radians: Double) -> Quat {
        let n = (axis * axis).sum().squareRoot()
        guard n > 1e-300 else { return .identity }
        let u = axis / n, h = radians / 2
        let s = sin(h)
        return Quat(cos(h), u.x * s, u.y * s, u.z * s)
    }

    public func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let u = SIMD3(x, y, z)
        let t = 2 * cross(u, v)
        return v + w * t + cross(u, t)
    }

    /// Rotation matrix, rows-first, matching `rotate`.
    public var matrix: Mat3 {
        let (ww, xx, yy, zz) = (w * w, x * x, y * y, z * z)
        return Mat3(SIMD3(ww + xx - yy - zz, 2 * (x * y - w * z), 2 * (x * z + w * y)),
                    SIMD3(2 * (x * y + w * z), ww - xx + yy - zz, 2 * (y * z - w * x)),
                    SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), ww - xx - yy + zz))
    }

    private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}

// MARK: - Crystal symmetry

/// The proper rotation group an orientation is only defined modulo.
public enum LatticeSymmetry {
    /// 432 — 24 proper rotations (fcc, bcc, simple cubic).
    case cubic
    /// 622 (D₆) — 12 proper rotations (hcp).
    case hexagonal
    /// No reduction (icosahedral clusters, unmatched atoms).
    case none

    public var operators: [Quat] {
        switch self {
        case .none: return [.identity]
        case .cubic: return LatticeSymmetry.cubicOperators
        case .hexagonal: return LatticeSymmetry.hexagonalOperators
        }
    }

    /// 1 identity + 3 twofold (⟨100⟩) + 6 fourfold (⟨100⟩) + 8 threefold
    /// (⟨111⟩) + 6 twofold (⟨110⟩) = 24.
    private static let cubicOperators: [Quat] = {
        let s = 0.5.squareRoot()
        var ops: [Quat] = [.identity,
                           Quat(0, 1, 0, 0), Quat(0, 0, 1, 0), Quat(0, 0, 0, 1),
                           Quat(s, s, 0, 0), Quat(s, -s, 0, 0),
                           Quat(s, 0, s, 0), Quat(s, 0, -s, 0),
                           Quat(s, 0, 0, s), Quat(s, 0, 0, -s),
                           Quat(0, s, s, 0), Quat(0, s, -s, 0),
                           Quat(0, s, 0, s), Quat(0, s, 0, -s),
                           Quat(0, 0, s, s), Quat(0, 0, s, -s)]
        for sx in [1.0, -1.0] {
            for sy in [1.0, -1.0] {
                for sz in [1.0, -1.0] { ops.append(Quat(0.5, 0.5 * sx, 0.5 * sy, 0.5 * sz)) }
            }
        }
        return ops
    }()

    /// 6 rotations by k·60° about c, and 6 twofold axes in the basal plane.
    private static let hexagonalOperators: [Quat] = {
        var ops: [Quat] = []
        for k in 0..<6 {
            let h = Double(k) * Double.pi / 6            // half of k·60°
            ops.append(Quat(cos(h), 0, 0, sin(h)))
            ops.append(Quat(0, cos(h), sin(h), 0))
        }
        return ops
    }()

    /// Smallest angle (radians) between two orientations, minimised over the
    /// symmetry group.
    ///
    /// The misorientation is M = q₁⁻¹q₂ and the equivalence class is
    /// {g₁ M g₂}. Rotation angle is invariant under conjugation, and
    /// g₂(g₁ M g₂)g₂⁻¹ = (g₂g₁)M with g₂g₁ still in the group, so the set of
    /// angles the two-sided class produces is exactly the set {angle(g M)} —
    /// one-sided is not an approximation here, it is the whole class.
    public static func disorientation(_ q1: Quat, _ q2: Quat, symmetry: LatticeSymmetry) -> Double {
        let m = q1.conjugate * q2
        var best = 0.0
        for g in symmetry.operators {
            let w = abs(Quat.scalarOfProduct(g, m))
            if w > best { best = w }
        }
        return 2 * acos(Swift.min(1, best))
    }
}

// MARK: - Horn's absolute orientation

/// Least-squares rotation between two point sets, by Horn's quaternion method.
///
/// A class rather than free functions because the 4×4 eigenproblem wants three
/// scratch buffers and PTM calls this tens of times per atom: a per-call array
/// allocation would cost more than the arithmetic.
public final class HornSolver {
    private var n = [Double](repeating: 0, count: 16)   // the symmetric 4×4
    private var v = [Double](repeating: 0, count: 16)   // accumulated eigenvectors

    public init() {}

    /// The rotation R minimising Σ|b_i − R a_i|², as a unit quaternion.
    /// Both sets are assumed already centred (PTM's neighbour vectors are
    /// relative to the central atom).
    public func rotation(from a: [SIMD3<Double>], to b: [SIMD3<Double>], count: Int) -> Quat {
        var s = Mat3.zero                                 // S = Σ aᵢ bᵢᵀ
        for i in 0..<count { s += Mat3.outer(a[i], b[i]) }
        return rotation(correlation: s)
    }

    /// Horn's N matrix from the 3×3 correlation S, then its dominant eigenvector.
    public func rotation(correlation s: Mat3) -> Quat {
        let (xx, xy, xz) = (s[0, 0], s[0, 1], s[0, 2])
        let (yx, yy, yz) = (s[1, 0], s[1, 1], s[1, 2])
        let (zx, zy, zz) = (s[2, 0], s[2, 1], s[2, 2])
        set(0, 0, xx + yy + zz); set(0, 1, yz - zy);       set(0, 2, zx - xz);        set(0, 3, xy - yx)
        set(1, 1, xx - yy - zz); set(1, 2, xy + yx);       set(1, 3, zx + xz)
        set(2, 2, -xx + yy - zz); set(2, 3, yz + zy)
        set(3, 3, -xx - yy + zz)
        let e = dominantEigenvector()
        return Quat(e.0, e.1, e.2, e.3).normalized()
    }

    private func set(_ i: Int, _ j: Int, _ value: Double) {
        n[i * 4 + j] = value
        n[j * 4 + i] = value
    }

    /// Cyclic Jacobi on the symmetric 4×4 in `n`, returning the eigenvector of
    /// the largest eigenvalue. Converges in a handful of sweeps at this size.
    private func dominantEigenvector() -> (Double, Double, Double, Double) {
        for i in 0..<16 { v[i] = (i % 5 == 0) ? 1 : 0 }
        var scale = 0.0
        for i in 0..<16 { scale += n[i] * n[i] }
        let converged = max(scale, 1e-300) * 1e-28      // relative: N scales with the point count
        for _ in 0..<12 {
            var off = 0.0
            for p in 0..<3 { for q in (p + 1)..<4 { off += n[p * 4 + q] * n[p * 4 + q] } }
            if off < converged { break }
            for p in 0..<3 {
                for q in (p + 1)..<4 {
                    let apq = n[p * 4 + q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (n[q * 4 + q] - n[p * 4 + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<4 {                       // columns p, q
                        let kp = n[k * 4 + p], kq = n[k * 4 + q]
                        n[k * 4 + p] = c * kp - s * kq
                        n[k * 4 + q] = s * kp + c * kq
                    }
                    for k in 0..<4 {                       // rows p, q
                        let pk = n[p * 4 + k], qk = n[q * 4 + k]
                        n[p * 4 + k] = c * pk - s * qk
                        n[q * 4 + k] = s * pk + c * qk
                    }
                    for k in 0..<4 {
                        let kp = v[k * 4 + p], kq = v[k * 4 + q]
                        v[k * 4 + p] = c * kp - s * kq
                        v[k * 4 + q] = s * kp + c * kq
                    }
                }
            }
        }
        var best = 0
        for i in 1..<4 where n[i * 4 + i] > n[best * 4 + best] { best = i }
        return (v[best], v[4 + best], v[8 + best], v[12 + best])
    }
}
