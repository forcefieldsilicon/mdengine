//
//  GrainSegmentation.swift — grains, boundaries and misorientation from a PTM
//  classification.
//
//  Two tools need the same answer: `PTMTool` reports grains as one row among
//  many, `GrainBoundaryTool` reports nothing else. Factored out here so the
//  union-find, the neighbour sweep and the disorientation convention are one
//  implementation and the two cannot drift apart (GJOB-235).
//
//  The comparison runs over every neighbour inside the structure-search radius,
//  not just the template's own vertices. That is deliberate: at a sharp boundary
//  the atoms *on* the interface match nothing, so the last matched atom of one
//  grain and the first of the other are two shells apart, and a 12-nearest test
//  would look straight past the boundary it is supposed to find.
//

import Foundation

/// Connected same-structure clusters whose neighbour disorientation stays below
/// `gbAngle`, plus the angles at the boundaries between them.
struct GrainSegmentation {
    /// True for an atom with at least one same-structure neighbour further than
    /// `gbAngle` away in orientation.
    let isBoundary: [Bool]
    /// Union-find root per atom; meaningful only where `classes[i] != .other`.
    let root: [Int]
    /// Atoms per cluster, keyed by root. Only sampled, matched atoms are counted.
    let clusterSize: [Int: Int]
    /// Largest disorientation (radians) to any same-structure neighbour. NaN for
    /// atoms that matched no template, or that have no comparable neighbour.
    let maxMisorientation: [Double]
    /// Sum and count of the disorientations over boundary pairs, counted once
    /// per pair (j > i).
    let boundaryAngleSum: Double
    let boundaryPairCount: Int
    /// Every one of those pair angles (radians), for the misorientation
    /// distribution. Same population as the sum above.
    let boundaryAngles: [Double]

    /// Mean disorientation over the boundary pairs, in radians; 0 with no pairs.
    var meanBoundaryAngle: Double {
        boundaryPairCount > 0 ? boundaryAngleSum / Double(boundaryPairCount) : 0
    }

    /// Clusters big enough to call a grain — a lone atom that happens to match
    /// fcc inside a melt is not a crystallite.
    func grainCount(minimumSize: Int) -> Int {
        clusterSize.values.filter { $0 >= minimumSize }.count
    }

    /// Roots of the counted grains, largest first (ties broken by root index so
    /// the labelling is deterministic).
    func grainRoots(minimumSize: Int) -> [Int] {
        clusterSize.filter { $0.value >= minimumSize }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    /// Sizes of the counted grains, largest first.
    func grainSizes(minimumSize: Int) -> [Int] {
        clusterSize.values.filter { $0 >= minimumSize }.sorted(by: >)
    }

    static func compute(count n: Int, stride: Int,
                        classes: [PTMClass], orientation: [Quat],
                        neighbors list: NeighborList, gbRadians: Double,
                        isCancelled: () -> Bool) throws -> GrainSegmentation {
        var isBoundary = [Bool](repeating: false, count: n)
        var maxAngle = [Double](repeating: .nan, count: n)
        var parent = Array(0..<n)
        func find(_ a: Int) -> Int {
            var root = a
            while parent[root] != root { root = parent[root] }
            var walk = a
            while parent[walk] != root { let next = parent[walk]; parent[walk] = root; walk = next }
            return root
        }
        var gbSum = 0.0, gbPairs = 0
        var gbAngles: [Double] = []

        for i in Swift.stride(from: 0, to: n, by: stride) where classes[i] != .other {
            if i % 1_024 == 0, isCancelled() { throw AnalysisError.cancelled }
            let symmetry = PTMTool.symmetry(of: classes[i])
            list.forEachNeighbor(of: i) { j, _ in
                guard j % stride == 0, classes[j] == classes[i] else { return }
                let angle = LatticeSymmetry.disorientation(orientation[i], orientation[j],
                                                           symmetry: symmetry)
                if !(maxAngle[i] >= angle) { maxAngle[i] = angle }   // NaN-safe max
                if angle > gbRadians {
                    isBoundary[i] = true
                    if j > i { gbSum += angle; gbPairs += 1; gbAngles.append(angle) }
                } else if find(i) != find(j) {
                    parent[find(j)] = find(i)
                }
            }
        }

        var root = [Int](repeating: -1, count: n)
        var clusterSize = [Int: Int]()
        for i in Swift.stride(from: 0, to: n, by: stride) where classes[i] != .other {
            let r = find(i)
            root[i] = r
            clusterSize[r, default: 0] += 1
        }
        return GrainSegmentation(isBoundary: isBoundary, root: root, clusterSize: clusterSize,
                                 maxMisorientation: maxAngle,
                                 boundaryAngleSum: gbSum, boundaryPairCount: gbPairs,
                                 boundaryAngles: gbAngles)
    }
}
