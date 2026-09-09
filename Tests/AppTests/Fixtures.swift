//
//  Fixtures.swift — synthetic lattices for the structural analysis tests.
//
//  Perfect crystals are the only fixtures with an exact expected answer, so the
//  structure tools are validated against them rather than against a recorded
//  trajectory. Lattice constants are the real ones (Al, Fe, Mg) so the numbers
//  in a failure message are recognisable.
//

import Foundation
@testable import LAMMPSCore

enum Fixtures {

    /// Face-centred cubic, `cells³` conventional cells, fully periodic.
    static func fcc(a: Double = 4.05, cells: Int = 6, element: String = "Al") -> Frame {
        build(basis: [SIMD3(0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0)],
              cell: SIMD3(a, a, a), cells: SIMD3(cells, cells, cells), element: element)
    }

    /// Body-centred cubic, `cells³` conventional cells, fully periodic.
    static func bcc(a: Double = 2.87, cells: Int = 6, element: String = "Fe") -> Frame {
        build(basis: [SIMD3(0, 0, 0), SIMD3(0.5, 0.5, 0.5)],
              cell: SIMD3(a, a, a), cells: SIMD3(cells, cells, cells), element: element)
    }

    /// Hexagonal close packed as its orthorhombic four-atom cell
    /// (a, √3·a, c) — periodic in all three directions.
    static func hcp(a: Double = 3.21, coa: Double = 1.633, cells: Int = 6,
                    element: String = "Mg") -> Frame {
        build(basis: [SIMD3(0, 0, 0), SIMD3(0.5, 0.5, 0),
                      SIMD3(0.5, 1.0 / 6.0, 0.5), SIMD3(0, 2.0 / 3.0, 0.5)],
              cell: SIMD3(a, 3.0.squareRoot() * a, coa * a),
              cells: SIMD3(cells, cells, cells), element: element)
    }

    /// An fcc lattice shaken apart: every atom displaced by a Gaussian of width
    /// `sigma`. σ = 0.6 Å on a 2.86 Å bond is well past the Lindemann melting
    /// criterion, so this stands in for a liquid/amorphous frame.
    static func liquid(a: Double = 4.05, cells: Int = 6, sigma: Double = 0.6,
                       seed: UInt64 = 0x5DEECE66D) -> Frame {
        let ordered = fcc(a: a, cells: cells)
        var rng = SplitMix64(seed: seed)
        let atoms = ordered.atoms.map { atom in
            Arv(element: atom.element,
                x: atom.x + rng.normal() * sigma,
                y: atom.y + rng.normal() * sigma,
                z: atom.z + rng.normal() * sigma)
        }
        return Frame(atoms: atoms, box: ordered.box)
    }

    /// The same fcc block with no cell at all: open boundaries, so the outer
    /// shell of atoms has an incomplete neighbourhood.
    static func fccSlabOpenBoundary(a: Double = 4.05, cells: Int = 5) -> Frame {
        Frame(atoms: fcc(a: a, cells: cells).atoms, box: nil)
    }

    /// Index of the atom closest to (`furthest: true` = furthest from) the
    /// geometric centre — the interior and corner probes of the open slab.
    static func atom(_ frame: Frame, furthest: Bool = false) -> Int {
        let p = frame.positions
        var lo = p[0], hi = p[0]
        for q in p {
            lo = SIMD3(min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z))
            hi = SIMD3(max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z))
        }
        let centre = (lo + hi) / 2
        var best = 0
        var bestDistance = furthest ? -Double.infinity : .infinity
        for i in 0..<p.count {
            let d = p[i] - centre
            let d2 = d.x * d.x + d.y * d.y + d.z * d.z
            if furthest ? (d2 > bestDistance) : (d2 < bestDistance) { bestDistance = d2; best = i }
        }
        return best
    }

    // MARK: - Construction

    private static func build(basis: [SIMD3<Double>], cell: SIMD3<Double>,
                              cells: SIMD3<Int>, element: String) -> Frame {
        var atoms: [Arv] = []
        atoms.reserveCapacity(basis.count * cells.x * cells.y * cells.z)
        for i in 0..<cells.x {
            for j in 0..<cells.y {
                for k in 0..<cells.z {
                    for b in basis {
                        atoms.append(Arv(element: element,
                                         x: (Double(i) + b.x) * cell.x,
                                         y: (Double(j) + b.y) * cell.y,
                                         z: (Double(k) + b.z) * cell.z))
                    }
                }
            }
        }
        let box = SimulationBox(lo: SIMD3(0, 0, 0),
                                hi: SIMD3(Double(cells.x) * cell.x,
                                          Double(cells.y) * cell.y,
                                          Double(cells.z) * cell.z))
        return Frame(atoms: atoms, box: box)
    }

    /// Deterministic across platforms — a test that melts differently on a
    /// different machine is not a test.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }

        /// Box–Muller; the second variate is discarded for simplicity.
        mutating func normal() -> Double {
            let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
        }
    }
}
