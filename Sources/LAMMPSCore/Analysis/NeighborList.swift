//
//  NeighborList.swift — O(N) cell-list neighbour finder.
//
//  Every structural tool (CNA, q̄6, contacts, coordination) needs "all atoms
//  within r of atom i". A brute-force sweep is O(N²) and dies at 10⁵ atoms; a
//  cell list of side ≥ cutoff makes it O(N) with a 27-cell sweep.
//

import Foundation

public final class NeighborList {
    public let cutoff: Double
    public let box: SimulationBox?
    /// True when the caller cancelled during the build — the list is then empty
    /// and every query returns nothing (callers discard cancelled results).
    public private(set) var wasCancelled = false

    private let positions: [SIMD3<Double>]
    private let cutoffSquared: Double
    /// Cell grid: origin/size/counts. Cells are at least `cutoff` wide.
    private var origin = SIMD3<Double>(repeating: 0)
    private var cellSize = SIMD3<Double>(repeating: 1)
    private var nCells = SIMD3<Int>(repeating: 1)
    private var periodic = [false, false, false]
    /// Atom indices bucketed by cell (counting sort): `bucket[start[c]..<start[c+1]]`.
    private var bucket: [Int] = []
    private var start: [Int] = []

    /// Builds the grid. `box == nil` = open boundaries, grid spans the atoms'
    /// bounding box. `isCancelled` is polled every ~10k atoms so a scrub or a
    /// window close does not pay for a build nobody will read.
    public init(positions: [SIMD3<Double>], cutoff: Double, box: SimulationBox?,
                isCancelled: (() -> Bool)? = nil) {
        self.positions = positions
        self.cutoff = max(cutoff, .leastNormalMagnitude)
        self.cutoffSquared = self.cutoff * self.cutoff
        self.box = box

        guard !positions.isEmpty else { start = [0]; return }

        // Grid extent: the cell when we have one, else the bounding box padded
        // by one cutoff so edge atoms are never outside the grid.
        var lo = positions[0], hi = positions[0]
        if let box {
            lo = box.lo; hi = box.hi
            periodic = [box.periodicX, box.periodicY, box.periodicZ]
        } else {
            for p in positions { lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                                 hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)) }
            lo -= SIMD3(repeating: self.cutoff)
            hi += SIMD3(repeating: self.cutoff)
        }
        origin = lo
        for axis in 0..<3 {
            let length = max(hi[axis] - lo[axis], self.cutoff)
            let n = max(1, Int(length / self.cutoff))
            nCells[axis] = n
            cellSize[axis] = length / Double(n)
        }

        // Counting sort into cells; one cancellation poll per 10k atoms.
        let total = nCells.x * nCells.y * nCells.z
        var counts = [Int](repeating: 0, count: total + 1)
        var cellOf = [Int](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            if i % 10_000 == 0, isCancelled?() == true { wasCancelled = true; start = [0]; return }
            let c = cellIndex(of: p)
            cellOf[i] = c
            counts[c + 1] += 1
        }
        for c in 1...total { counts[c] += counts[c - 1] }
        start = counts
        bucket = [Int](repeating: 0, count: positions.count)
        var fill = counts
        for i in 0..<positions.count {
            if i % 10_000 == 0, isCancelled?() == true { wasCancelled = true; bucket = []; start = [0]; return }
            let c = cellOf[i]
            bucket[fill[c]] = i
            fill[c] += 1
        }
    }

    public convenience init(frame: Frame, cutoff: Double, isCancelled: (() -> Bool)? = nil) {
        self.init(positions: frame.positions, cutoff: cutoff, box: frame.box, isCancelled: isCancelled)
    }

    /// Indices of every atom within `cutoff` of `i` (excluding `i`).
    public func neighbors(of i: Int) -> [Int] {
        var out: [Int] = []
        forEachNeighbor(of: i) { j, _ in out.append(j) }
        return out
    }

    /// Visits every neighbour of `i` with its distance (Å) — the allocation-free
    /// form tools should use inside per-atom loops.
    public func forEachNeighbor(of i: Int, _ body: (Int, Double) -> Void) {
        guard !wasCancelled, i >= 0, i < positions.count, !bucket.isEmpty else { return }
        let p = positions[i]
        let c = cellCoord(of: p)
        for cx in sweep(c.x, axis: 0) {
            for cy in sweep(c.y, axis: 1) {
                for cz in sweep(c.z, axis: 2) {
                    let cell = (cx * nCells.y + cy) * nCells.z + cz
                    for k in start[cell]..<start[cell + 1] {
                        let j = bucket[k]
                        guard j != i else { continue }
                        var d = positions[j] - p
                        if let box { d = box.minimumImage(d) }
                        let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                        if d2 <= cutoffSquared { body(j, d2.squareRoot()) }
                    }
                }
            }
        }
    }

    /// The `k` nearest neighbours of `i` within the cutoff, nearest first.
    /// Returns fewer than `k` when the cutoff does not contain that many.
    public func kNearest(of i: Int, k: Int) -> [(index: Int, distance: Double)] {
        guard k > 0 else { return [] }
        var found: [(index: Int, distance: Double)] = []
        forEachNeighbor(of: i) { j, d in found.append((j, d)) }
        found.sort { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
        return Array(found.prefix(k))
    }

    // MARK: - Grid helpers

    private func cellCoord(of p: SIMD3<Double>) -> SIMD3<Int> {
        let q = box?.wrap(p) ?? p
        var c = SIMD3<Int>(repeating: 0)
        for axis in 0..<3 {
            let raw = Int((q[axis] - origin[axis]) / cellSize[axis])
            c[axis] = min(max(raw, 0), nCells[axis] - 1)
        }
        return c
    }

    private func cellIndex(of p: SIMD3<Double>) -> Int {
        let c = cellCoord(of: p)
        return (c.x * nCells.y + c.y) * nCells.z + c.z
    }

    /// The distinct cell coordinates to visit along one axis. With fewer than
    /// three cells on a periodic axis the naive -1/0/+1 sweep would visit the
    /// same cell twice and double-count neighbours, so the offsets shrink.
    private func sweep(_ c: Int, axis: Int) -> [Int] {
        let n = nCells[axis]
        if periodic[axis] && box != nil {
            switch n {
            case 1: return [c]
            case 2: return [c, (c + 1) % 2]
            default: return [(c + n - 1) % n, c, (c + 1) % n]
            }
        }
        return [c - 1, c, c + 1].filter { $0 >= 0 && $0 < n }
    }
}
