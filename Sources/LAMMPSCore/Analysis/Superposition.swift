//
//  Superposition.swift — rigid-body fitting, and "which atoms do I fit on".
//
//  Every conformational number (RMSD, RMSF, a PCA of a trajectory, a cluster
//  of frames) is a comparison of shapes, so the tumbling has to come out first.
//  Kabsch's optimal rotation is done here in Horn's quaternion form: the 4×4
//  symmetric matrix built from the correlation has the rotation as its largest
//  eigenvector, and a Jacobi sweep on a 4×4 is both self-contained (no LAPACK)
//  and immune to the reflection case that a naive SVD implementation gets
//  wrong. The same Jacobi routine serves the 3×3 gyration/covariance work.
//

import Foundation

/// Cyclic Jacobi eigen-decomposition of a small dense symmetric matrix.
/// Values come back descending, `vectors[k]` is the unit eigenvector for
/// `values[k]`. Small and dense is the whole design envelope (3×3, 4×4).
public enum SymmetricEigen {
    public static func jacobi(_ input: [[Double]], sweeps: Int = 64)
        -> (values: [Double], vectors: [[Double]]) {
        let n = input.count
        var a = input
        var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<sweeps {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += a[p][q] * a[p][q] } }
            if off <= 1e-24 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-30 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let order = (0..<n).sorted { a[$0][$0] > a[$1][$1] }
        return (order.map { a[$0][$0] }, order.map { j in (0..<n).map { v[$0][j] } })
    }
}

/// The rigid transform that best maps `mobile` onto `reference`, plus the RMSD
/// that remains. `apply` is the map: `rotation * p + translation`.
public struct Superposition {
    public let rotation: Mat3
    public let translation: SIMD3<Double>
    public let mobileCentroid: SIMD3<Double>
    public let referenceCentroid: SIMD3<Double>
    /// RMSD after the fit (Å), over the atoms the fit was made on.
    public let rmsd: Double

    public func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { rotation * p + translation }

    /// Kabsch/Horn fit. `weights` defaults to 1 per point; nil is returned for
    /// mismatched or empty inputs (never a silent identity).
    public static func fit(mobile: [SIMD3<Double>], reference: [SIMD3<Double>],
                           weights: [Double]? = nil) -> Superposition? {
        guard !mobile.isEmpty, mobile.count == reference.count else { return nil }
        if let w = weights, w.count != mobile.count { return nil }
        var wsum = 0.0
        var cm = SIMD3<Double>(repeating: 0), cr = SIMD3<Double>(repeating: 0)
        for i in mobile.indices {
            let w = weights?[i] ?? 1
            guard w > 0 else { continue }
            wsum += w; cm += mobile[i] * w; cr += reference[i] * w
        }
        guard wsum > 0 else { return nil }
        cm /= wsum; cr /= wsum

        // Correlation S_ab = Σ w (mobile−cm)_a (reference−cr)_b.
        var s = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in mobile.indices {
            let w = weights?[i] ?? 1
            guard w > 0 else { continue }
            let x = mobile[i] - cm, y = reference[i] - cr
            for a in 0..<3 { for b in 0..<3 { s[a][b] += w * x[a] * y[b] } }
        }
        let (sxx, sxy, sxz) = (s[0][0], s[0][1], s[0][2])
        let (syx, syy, syz) = (s[1][0], s[1][1], s[1][2])
        let (szx, szy, szz) = (s[2][0], s[2][1], s[2][2])
        let k: [[Double]] = [
            [sxx + syy + szz, syz - szy,        szx - sxz,        sxy - syx],
            [syz - szy,       sxx - syy - szz,  sxy + syx,        szx + sxz],
            [szx - sxz,       sxy + syx,       -sxx + syy - szz,  syz + szy],
            [sxy - syx,       szx + sxz,        syz + szy,       -sxx - syy + szz]
        ]
        let q = SymmetricEigen.jacobi(k).vectors[0]          // largest eigenvalue
        let (q0, q1, q2, q3) = (q[0], q[1], q[2], q[3])
        let rotation = Mat3(
            SIMD3(q0 * q0 + q1 * q1 - q2 * q2 - q3 * q3, 2 * (q1 * q2 - q0 * q3), 2 * (q1 * q3 + q0 * q2)),
            SIMD3(2 * (q2 * q1 + q0 * q3), q0 * q0 - q1 * q1 + q2 * q2 - q3 * q3, 2 * (q2 * q3 - q0 * q1)),
            SIMD3(2 * (q3 * q1 - q0 * q2), 2 * (q3 * q2 + q0 * q1), q0 * q0 - q1 * q1 - q2 * q2 + q3 * q3))
        let translation = cr - rotation * cm

        var sq = 0.0
        for i in mobile.indices {
            let w = weights?[i] ?? 1
            guard w > 0 else { continue }
            let d = rotation * mobile[i] + translation - reference[i]
            sq += w * (d * d).sum()
        }
        return Superposition(rotation: rotation, translation: translation,
                             mobileCentroid: cm, referenceCentroid: cr,
                             rmsd: (sq / wsum).squareRoot())
    }

    /// RMSD as the coordinates stand — no rotation, no translation removed.
    public static func rmsdNoFit(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>],
                                 weights: [Double]? = nil) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .nan }
        var sq = 0.0, wsum = 0.0
        for i in a.indices {
            let w = weights?[i] ?? 1
            guard w > 0 else { continue }
            let d = a[i] - b[i]
            sq += w * (d * d).sum(); wsum += w
        }
        return wsum > 0 ? (sq / wsum).squareRoot() : .nan
    }

    /// RMSD after the optimal fit (NaN when the fit is impossible).
    public static func rmsd(mobile: [SIMD3<Double>], reference: [SIMD3<Double>],
                            weights: [Double]? = nil) -> Double {
        fit(mobile: mobile, reference: reference, weights: weights)?.rmsd ?? .nan
    }
}

/// Which atoms a conformational study is *about*. Protein work fits on Cα or
/// the backbone; a frame with no `name` column (a plain dump) still has to
/// produce something honest, so those fall back to heavy atoms with a note
/// rather than selecting nothing.
public enum AtomSelection {
    public static let names = ["ca", "backbone", "heavy", "all"]
    private static let backboneNames: Set<String> = ["N", "CA", "C", "O"]

    public struct Selection {
        public let indices: [Int]
        /// What was actually used ("ca", "heavy"…) — may differ from the request.
        public let resolved: String
        public let note: String?
    }

    public static func select(_ request: String, in frame: Frame, within group: [Int]? = nil) -> Selection {
        let pool = group ?? Array(0..<frame.count)
        let key = request.trimmingCharacters(in: .whitespaces).lowercased()
        func heavy() -> [Int] { pool.filter { Groups.normalizedElement(frame.atoms[$0].element) != "H" } }

        switch key {
        case "all":
            return Selection(indices: pool, resolved: "all", note: nil)
        case "heavy":
            return Selection(indices: heavy(), resolved: "heavy", note: nil)
        case "ca", "backbone":
            guard let labels = frame.label("name") else {
                return Selection(indices: heavy(), resolved: "heavy",
                                 note: "No `name` column in this frame — “\(key)” fell back to heavy atoms.")
            }
            let want: Set<String> = key == "ca" ? ["CA"] : backboneNames
            let picked = pool.filter { want.contains(labels[$0].trimmingCharacters(in: .whitespaces).uppercased()) }
            if picked.isEmpty {
                return Selection(indices: heavy(), resolved: "heavy",
                                 note: "No atoms named \(want.sorted().joined(separator: "/")) — “\(key)” fell back to heavy atoms.")
            }
            return Selection(indices: picked, resolved: key, note: nil)
        default:
            return Selection(indices: pool, resolved: "all",
                             note: "Unknown selection “\(request)” — used all atoms (\(names.joined(separator: ", "))).")
        }
    }
}
