//
//  BondOrder.swift — Steinhardt bond-orientational order, averaged form.
//
//  q_lm(i) is the mean of the spherical harmonics over the bonds of atom i
//  (Steinhardt, Nelson & Ronchetti 1983, PRB 28 784). The *averaged* q̄_lm of
//  Lechner & Dellago (2008, JCP 129 114707) additionally averages q_lm over i
//  and its own neighbours, which separates liquid from crystal far better than
//  the raw form — that is the version used here.
//
//  l = 4 and l = 6 are the useful ones for close-packed metals; the associated
//  Legendre recurrences below are general in l, so nothing here is table-driven
//  and there is no external dependency.
//

import Foundation

public enum BondOrder {

    /// Averaged Steinhardt order parameter q̄_l for every atom.
    ///
    /// - Parameters:
    ///   - l: harmonic degree (4 and 6 are the physically meaningful ones).
    ///   - positions: one entry per atom.
    ///   - neighbors: bond partners per atom, parallel to `positions`
    ///     (the 12 nearest, or everything inside a fixed cutoff).
    ///   - box: when present, bond vectors use the minimum image.
    /// - Returns: q̄_l per atom; 0 for atoms with no neighbours.
    ///
    /// Reference values for perfect lattices with 12 neighbours: fcc q̄6 ≈ 0.575,
    /// q̄4 ≈ 0.191; hcp q̄6 ≈ 0.485; a simple liquid sits near q̄6 ≈ 0.3.
    public static func averagedQ(l: Int, positions: [SIMD3<Double>],
                                 neighbors: [[Int]], box: SimulationBox? = nil) -> [Double] {
        let n = positions.count
        guard n > 0, l > 0, neighbors.count == n else { return [Double](repeating: 0, count: n) }
        let mCount = l + 1                    // m = 0…l; negative m follows by symmetry
        let norm = normalizations(l: l)

        // Step 1: q_lm(i), the bond average of Y_lm. Flat storage: [atom][m].
        var qlm = [Complex](repeating: .zero, count: n * mCount)
        var harmonic = [Complex](repeating: .zero, count: mCount)
        var legendre = [Double](repeating: 0, count: mCount)
        for i in 0..<n {
            let nb = neighbors[i]
            guard !nb.isEmpty else { continue }
            var used = 0
            for j in nb where j >= 0 && j < n && j != i {
                var d = positions[j] - positions[i]
                if let box { d = box.minimumImage(d) }
                let r = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
                guard r > 0 else { continue }
                harmonics(l: l, u: d / r, norm: norm, legendre: &legendre, into: &harmonic)
                for m in 0..<mCount { qlm[i * mCount + m] += harmonic[m] }
                used += 1
            }
            guard used > 0 else { continue }
            let inv = 1.0 / Double(used)
            for m in 0..<mCount { qlm[i * mCount + m] *= inv }
        }

        // Step 2: q̄_lm = mean of q_lm over i and its neighbours, then the norm
        // q̄_l = sqrt(4π/(2l+1) · Σ_m |q̄_lm|²), with |q̄_l,-m| = |q̄_lm|.
        var out = [Double](repeating: 0, count: n)
        let prefactor = 4.0 * Double.pi / Double(2 * l + 1)
        for i in 0..<n {
            let nb = neighbors[i]
            var sum = 0.0
            for m in 0..<mCount {
                var acc = qlm[i * mCount + m]
                var shells = 1
                for j in nb where j >= 0 && j < n {
                    acc += qlm[j * mCount + m]
                    shells += 1
                }
                acc *= 1.0 / Double(shells)
                let magnitude = acc.re * acc.re + acc.im * acc.im
                sum += (m == 0 ? magnitude : 2 * magnitude)
            }
            out[i] = (prefactor * sum).squareRoot()
        }
        return out
    }

    // MARK: - Spherical harmonics

    /// Minimal complex number — a struct beats a tuple here because of `+=`.
    struct Complex {
        var re: Double
        var im: Double
        static let zero = Complex(re: 0, im: 0)
        init(re: Double, im: Double) { self.re = re; self.im = im }
        static func += (a: inout Complex, b: Complex) { a.re += b.re; a.im += b.im }
        static func *= (a: inout Complex, s: Double) { a.re *= s; a.im *= s }
    }

    /// N_lm = sqrt((2l+1)/(4π) · (l−m)!/(l+m)!) for m = 0…l.
    static func normalizations(l: Int) -> [Double] {
        (0...l).map { m in
            var ratio = 1.0                        // (l−m)!/(l+m)!
            if m > 0 { for k in (l - m + 1)...(l + m) { ratio /= Double(k) } }
            return (Double(2 * l + 1) / (4 * Double.pi) * ratio).squareRoot()
        }
    }

    /// Y_lm(θ, φ) for m = 0…l from the unit bond vector `u` (Condon–Shortley
    /// phase included; it cancels in |q̄_lm| but keeps the convention standard).
    static func harmonics(l: Int, u: SIMD3<Double>, norm: [Double],
                          legendre: inout [Double], into y: inout [Complex]) {
        let x = max(-1.0, min(1.0, u.z))          // cos θ
        associatedLegendre(l: l, x: x, into: &legendre)
        // e^{iφ} from the in-plane part; at the poles P_l^m = 0 for m ≥ 1, so
        // the arbitrary choice below never reaches the result.
        let s = (u.x * u.x + u.y * u.y).squareRoot()
        let cosPhi = s > 0 ? u.x / s : 1.0
        let sinPhi = s > 0 ? u.y / s : 0.0
        var c = 1.0, sn = 0.0                     // cos(mφ), sin(mφ) by rotation
        for m in 0...l {
            let a = norm[m] * legendre[m]
            y[m] = Complex(re: a * c, im: a * sn)
            let nextC = c * cosPhi - sn * sinPhi
            sn = sn * cosPhi + c * sinPhi
            c = nextC
        }
    }

    /// P_l^m(x) for m = 0…l via the textbook three-term recurrences:
    /// P_m^m = (−1)^m (2m−1)!! (1−x²)^{m/2}, P_{m+1}^m = x(2m+1)P_m^m,
    /// P_l^m = [x(2l−1)P_{l−1}^m − (l+m−1)P_{l−2}^m] / (l−m).
    static func associatedLegendre(l: Int, x: Double, into p: inout [Double]) {
        let sinTheta = max(0, 1 - x * x).squareRoot()
        for m in 0...l {
            var pmm = 1.0
            if m > 0 {
                var oddFactor = 1.0
                for _ in 1...m { pmm *= -oddFactor * sinTheta; oddFactor += 2.0 }
            }
            if m == l { p[m] = pmm; continue }
            var previous = pmm
            var current = x * Double(2 * m + 1) * pmm      // P_{m+1}^m
            var degree = m + 2
            while degree <= l {
                let next = (x * Double(2 * degree - 1) * current
                            - Double(degree + m - 1) * previous) / Double(degree - m)
                previous = current
                current = next
                degree += 1
            }
            p[m] = current
        }
    }
}
