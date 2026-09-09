//
//  SimulationBox.swift — the simulation cell and its periodic boundaries.
//
//  Analysis tools that measure distances (neighbour lists, RDFs, strain) are
//  wrong by a whole box length at the edges unless they wrap; every tool that
//  needs one declares `.box` in its requirements and stays idle without it.
//

import Foundation

/// An orthogonal simulation cell with per-axis periodicity.
///
/// Triclinic tilt factors (`xy xz yz`) are *stored* when a dump carries them so
/// nothing is lost on the way in, but `minimumImage`/`wrap` treat the cell as
/// orthogonal — triclinic images are phase-2 work. `isTriclinic` lets a tool
/// warn rather than silently report skewed distances.
public struct SimulationBox: Codable, Equatable {
    public var lo: SIMD3<Double>
    public var hi: SIMD3<Double>
    /// Periodic flags per axis (LAMMPS `pp`), false = fixed/shrink-wrapped.
    public var periodicX: Bool
    public var periodicY: Bool
    public var periodicZ: Bool
    /// Triclinic tilt (xy, xz, yz); nil for an orthogonal cell.
    public var tilt: SIMD3<Double>?

    public init(lo: SIMD3<Double>, hi: SIMD3<Double>,
                periodicX: Bool = true, periodicY: Bool = true, periodicZ: Bool = true,
                tilt: SIMD3<Double>? = nil) {
        self.lo = lo
        self.hi = hi
        self.periodicX = periodicX
        self.periodicY = periodicY
        self.periodicZ = periodicZ
        self.tilt = tilt
    }

    /// Edge lengths (Å). Never negative — a degenerate axis reports 0.
    public var lengths: SIMD3<Double> {
        SIMD3(max(0, hi.x - lo.x), max(0, hi.y - lo.y), max(0, hi.z - lo.z))
    }

    public var center: SIMD3<Double> { (lo + hi) / 2 }

    /// True when tilt factors are present and non-zero.
    public var isTriclinic: Bool {
        guard let t = tilt else { return false }
        return t.x != 0 || t.y != 0 || t.z != 0
    }

    public func isPeriodic(axis: Int) -> Bool {
        switch axis {
        case 0: return periodicX
        case 1: return periodicY
        default: return periodicZ
        }
    }

    /// Shortest separation vector for a raw difference `d`, per the minimum
    /// image convention on periodic axes. Orthogonal cells only.
    public func minimumImage(_ d: SIMD3<Double>) -> SIMD3<Double> {
        let l = lengths
        var out = d
        for axis in 0..<3 where isPeriodic(axis: axis) && l[axis] > 0 {
            out[axis] -= l[axis] * (out[axis] / l[axis]).rounded()
        }
        return out
    }

    /// Fold a position back inside the cell on periodic axes.
    public func wrap(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let l = lengths
        var out = p
        for axis in 0..<3 where isPeriodic(axis: axis) && l[axis] > 0 {
            let rel = (out[axis] - lo[axis]).truncatingRemainder(dividingBy: l[axis])
            out[axis] = lo[axis] + (rel < 0 ? rel + l[axis] : rel)
        }
        return out
    }
}
