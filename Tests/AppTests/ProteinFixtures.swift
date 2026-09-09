import Foundation
@testable import LAMMPSCore

/// Backbone fixtures built from internal coordinates (NeRF), so the secondary
/// structure is what the geometry says it is and not what a PDB file claimed.
/// Standard peptide geometry; only N, CA, C, O are placed — DSSP needs nothing
/// else, and a fixture with side chains would only hide the backbone.
enum ProteinFixtures {

    // Bond lengths (Å) and angles (deg) — Engh & Huber values, rounded.
    private static let bNCA = 1.458, bCAC = 1.525, bCN = 1.329, bCO = 1.231
    private static let aNCAC = 111.2, aCACN = 116.2, aCNCA = 121.7, aCACO = 120.8
    private static let omega = 180.0

    struct Atom {
        let name: String, element: String, resname: String, chain: String, resid: Int
        var p: SIMD3<Double>
    }

    // MARK: - Geometry helpers

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    static func norm(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / max(norm(v), 1e-12) }

    /// NeRF: place D given A–B–C, |CD|, ∠BCD and the dihedral A–B–C–D (deg).
    static func place(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                      bond: Double, angle: Double, torsion: Double) -> SIMD3<Double> {
        let bc = unit(c - b)
        let n = unit(cross(b - a, bc))
        let p = cross(n, bc)
        let th = angle * .pi / 180, ph = torsion * .pi / 180
        return c + (bc * (-bond * cos(th)))
                 + (p * (bond * sin(th) * cos(ph)))
                 + (n * (bond * sin(th) * sin(ph)))
    }

    /// The A–B–C–D dihedral in degrees — used by the tests to prove the builder.
    static func dihedral(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                         _ c: SIMD3<Double>, _ d: SIMD3<Double>) -> Double {
        let b1 = b - a, b2 = c - b, b3 = d - c
        let n1 = cross(b1, b2), n2 = cross(b2, b3)
        let m = cross(n1, unit(b2))
        return -atan2((m * n2).sum(), (n1 * n2).sum()) * 180 / .pi
    }

    // MARK: - Builders

    /// A backbone of `residues` alanines at constant (φ, ψ).
    static func backbone(residues: Int, phi: Double, psi: Double,
                         chain: String = "A", resname: String = "ALA") -> [Atom] {
        var atoms: [Atom] = []
        var n = SIMD3<Double>(0, 0, 0)
        var ca = SIMD3<Double>(bNCA, 0, 0)
        let th = aNCAC * .pi / 180
        var c = ca + SIMD3(-cos(th), -sin(th), 0) * bCAC
        for i in 0..<residues {
            if i > 0 {
                let (pn, pca, pc) = (atoms[atoms.count - 4].p, atoms[atoms.count - 3].p, atoms[atoms.count - 2].p)
                n = place(pn, pca, pc, bond: bCN, angle: aCACN, torsion: psi)
                ca = place(pca, pc, n, bond: bNCA, angle: aCNCA, torsion: omega)
                c = place(pc, n, ca, bond: bCAC, angle: aNCAC, torsion: phi)
            }
            let o = place(n, ca, c, bond: bCO, angle: aCACO, torsion: psi + 180)
            atoms.append(Atom(name: "N", element: "N", resname: resname, chain: chain, resid: i + 1, p: n))
            atoms.append(Atom(name: "CA", element: "C", resname: resname, chain: chain, resid: i + 1, p: ca))
            atoms.append(Atom(name: "C", element: "C", resname: resname, chain: chain, resid: i + 1, p: c))
            atoms.append(Atom(name: "O", element: "O", resname: resname, chain: chain, resid: i + 1, p: o))
        }
        return atoms
    }

    static func frame(_ atoms: [Atom], withNames: Bool = true) -> Frame {
        let arvs = atoms.map { Arv(element: $0.element, x: $0.p.x, y: $0.p.y, z: $0.p.z) }
        guard withNames else { return Frame(atoms: arvs) }
        return Frame(atoms: arvs, labels: [
            "name": atoms.map { $0.name },
            "resname": atoms.map { $0.resname },
            "resid": atoms.map { String($0.resid) },
            "chain": atoms.map { $0.chain }
        ])
    }

    /// Ideal right-handed α-helix (φ = −57°, ψ = −47°).
    static func alphaHelix(residues: Int = 12) -> Frame {
        frame(backbone(residues: residues, phi: -57, psi: -47))
    }

    /// Two ideal β-strands (φ = −120°, ψ = +130°) placed as an antiparallel
    /// pair: strand B is strand A rotated 180° about the sheet normal, which is
    /// the two-fold symmetry a real antiparallel sheet has. `shift` slides the
    /// axis along the strand to set the hydrogen-bond register.
    static func antiparallelSheet(residues: Int = 8, separation: Double = 4.85,
                                  shift: Double = 1.5) -> Frame {
        let a = backbone(residues: residues, phi: -120, psi: 130, chain: "A")
        let cas = a.filter { $0.name == "CA" }.map { $0.p }
        let u = unit(cas[cas.count - 1] - cas[0])
        let mid = residues / 2
        let cIndex = mid * 4 + 2, oIndex = mid * 4 + 3
        let co = a[oIndex].p - a[cIndex].p
        let w = unit(co - u * (co * u).sum())
        let n = unit(cross(u, w))
        var centre = SIMD3<Double>(repeating: 0)
        for p in cas { centre += p }
        centre /= Double(cas.count)
        let pivot = centre + w * (separation / 2) + u * shift
        // Rotation by π about `n`: R = 2nnᵀ − I (a proper rotation, det = +1).
        func rotate(_ x: SIMD3<Double>) -> SIMD3<Double> {
            let d = x - pivot
            return pivot + n * (2 * (n * d).sum()) - d
        }
        let b = a.map { Atom(name: $0.name, element: $0.element, resname: $0.resname,
                             chain: "B", resid: $0.resid, p: rotate($0.p)) }
        return frame(a + b)
    }

    /// Same helix with the `name` column stripped — the "DSSP cannot run" case.
    static func helixWithoutNames(residues: Int = 12) -> Frame {
        frame(backbone(residues: residues, phi: -57, psi: -47), withNames: false)
    }
}
