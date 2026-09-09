//
//  CrystallinityTool.swift — crystallinity, amorphicity, fcc/hcp/bcc per atom.
//
//  Design §2.1. Two complementary readings of the same neighbourhood:
//
//  * **adaptive common neighbour analysis** (a-CNA, Stukowski 2012, Modelling
//    Simul. Mater. Sci. Eng. 20 045021) — a discrete structure label per atom
//    with no cutoff to tune, the de-facto standard (this is what OVITO shows);
//  * **averaged Steinhardt q̄4/q̄6** (`BondOrder.swift`) — a continuous order
//    parameter, so "amorphous" is a number rather than the leftover bucket.
//
//  Both are always computed: the summary carries the structure fractions *and*
//  the mean q̄6/q̄4, and `method` only decides which one colours the atoms and
//  which definition of "crystalline" the fraction, profile and scalar use.
//

import Foundation

/// Per-atom structure class. The raw values are the field values, so they must
/// stay in step with the categorical palette below.
public enum StructureType: Int, CaseIterable {
    case other = 0, fcc, hcp, bcc, ico

    public var label: String {
        switch self {
        case .other: return "Other"
        case .fcc: return "FCC"
        case .hcp: return "HCP"
        case .bcc: return "BCC"
        case .ico: return "Icosahedral"
        }
    }

    /// OVITO's colours, so a figure from MDEngine reads like every other figure
    /// in the field. Grey is "other" (amorphous, surface, grain boundary).
    public var color: RGB {
        switch self {
        case .other: return RGB(0.6, 0.6, 0.6)
        case .fcc: return RGB(0.4, 1.0, 0.4)
        case .hcp: return RGB(1.0, 0.4, 0.4)
        case .bcc: return RGB(0.4, 0.4, 1.0)
        case .ico: return RGB(0.95, 0.8, 0.2)
        }
    }
}

public struct CrystallinityTool: AnalysisTool {
    public static let id = "crystallinity"
    public static let title = "Crystallinity"
    public static let category = ToolCategory.structureOrder
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    /// No box needed — CNA is local. A box, when present, is used for the
    /// minimum image; without one the outer surface classifies as "other",
    /// which is the honest answer for an open boundary.
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    public enum Method: String, Codable, Equatable, CaseIterable {
        /// Adaptive common neighbour analysis: discrete structure per atom.
        case acna
        /// Averaged Steinhardt q̄6 with a threshold: continuous order.
        case q6
    }

    public struct Parameters: Codable, Equatable {
        public var method: Method
        /// q̄6 above this counts as ordered when `method == .q6`.
        public var q6Threshold: Double
        /// nil = adaptive cutoff per atom (a-CNA). A value switches to
        /// conventional CNA with that fixed bond cutoff.
        public var cutoff: Double?
        public var profileAxis: Axis
        public var bins: Int

        public init(method: Method = .acna, q6Threshold: Double = 0.5,
                    cutoff: Double? = nil, profileAxis: Axis = .z, bins: Int = 24) {
            self.method = method
            self.q6Threshold = q6Threshold
            self.cutoff = cutoff
            self.profileAxis = profileAxis
            self.bins = bins
        }
    }

    public static let defaultParameters = Parameters()

    /// Order-of-magnitude only, until the governor has measured this tool.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double {
        (params.method == .q6 ? 4.0 : 1.5) * Double(atoms)
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        let n = frame.count
        guard n > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        if context.isCancelled() { throw AnalysisError.cancelled }

        let positions = frame.positions
        let fixedCutoff = params.cutoff.flatMap { $0 > 0 ? $0 : nil }
        let buildCutoff = fixedCutoff ?? estimateBuildCutoff(frame: frame, positions: positions,
                                                             context: context)
        let list = context.neighborList(for: frame, cutoff: buildCutoff)
        if list.wasCancelled || context.isCancelled() { throw AnalysisError.cancelled }

        // One pass: the neighbour set each atom is classified on, and the bond
        // set the Steinhardt sum runs over (they are the same neighbours).
        let stride = max(1, context.stride)
        var types = [StructureType](repeating: .other, count: n)
        var bonds = [[Int]]()
        bonds.reserveCapacity(n)
        let cna = CNAClassifier()
        for i in 0..<n {
            if i % 2_048 == 0, context.isCancelled() { throw AnalysisError.cancelled }
            if let rc = fixedCutoff {
                let neighbors = list.neighbors(of: i)
                bonds.append(neighbors)
                if i % stride == 0 {
                    types[i] = cna.classifyConventional(center: i, neighbors: neighbors,
                                                        cutoff: rc, positions: positions,
                                                        box: frame.box)
                }
            } else {
                let nearest = list.kNearest(of: i, k: CNAClassifier.bccNeighbors)
                bonds.append(nearest.prefix(CNAClassifier.fccNeighbors).map(\.index))
                if i % stride == 0 {
                    types[i] = cna.classifyAdaptive(center: i, neighbors: nearest,
                                                    positions: positions, box: frame.box)
                }
            }
        }

        let q6 = BondOrder.averagedQ(l: 6, positions: positions, neighbors: bonds, box: frame.box)
        let q4 = BondOrder.averagedQ(l: 4, positions: positions, neighbors: bonds, box: frame.box)
        if context.isCancelled() { throw AnalysisError.cancelled }

        // Statistics over the atoms that were actually classified.
        var counts = [Int](repeating: 0, count: StructureType.allCases.count)
        var sampled = 0, ordered = 0
        var sumQ6 = 0.0, sumQ4 = 0.0
        for i in Swift.stride(from: 0, to: n, by: stride) {
            counts[types[i].rawValue] += 1
            sampled += 1
            sumQ6 += q6[i]
            sumQ4 += q4[i]
            if params.method == .q6 ? (q6[i] > params.q6Threshold) : (types[i] != .other) { ordered += 1 }
        }
        let inverse = 1.0 / Double(max(1, sampled))
        let crystallineFraction = Double(ordered) * inverse
        let meanQ6 = sumQ6 * inverse, meanQ4 = sumQ4 * inverse

        // Per-atom field. Atoms the stride skipped keep 0 — "other" for a-CNA,
        // the bottom of the ramp for q̄6 — and the note says so.
        let crystalline: [Float] = (0..<n).map { i in
            guard i % stride == 0 else { return 0 }
            let isOrdered = params.method == .q6 ? (q6[i] > params.q6Threshold) : (types[i] != .other)
            return isOrdered ? 1 : 0
        }
        let field: PerAtomField
        switch params.method {
        case .acna:
            field = PerAtomField(name: "structure",
                                 values: types.map { Float($0.rawValue) },
                                 palette: .categorical(StructureType.allCases.map { ($0.label, $0.color) }),
                                 legendTitle: "Structure (a-CNA)")
        case .q6:
            field = PerAtomField(name: "q6_avg",
                                 values: (0..<n).map { i in i % stride == 0 ? Float(q6[i]) : 0 },
                                 palette: .continuous(min: 0, max: 0.6, colormapName: "viridis"),
                                 legendTitle: "q̄6")
        }

        func percent(_ x: Double) -> String { String(format: "%.1f", x * 100) }
        var summary: [SummaryRow] = StructureType.allCases.map {
            SummaryRow($0.label, percent(Double(counts[$0.rawValue]) * inverse), unit: "%")
        }
        summary.append(SummaryRow("Crystalline fraction", percent(crystallineFraction), unit: "%"))
        summary.append(SummaryRow("Amorphicity index", percent(1 - crystallineFraction), unit: "%"))
        summary.append(SummaryRow("Mean q̄6", String(format: "%.4f", meanQ6)))
        summary.append(SummaryRow("Mean q̄4", String(format: "%.4f", meanQ4)))
        summary.append(SummaryRow("Method", params.method == .q6
                                  ? "averaged q̄6 > \(String(format: "%.2f", params.q6Threshold))"
                                  : "adaptive CNA"))
        summary.append(SummaryRow("Cutoff", fixedCutoff.map { String(format: "%.3f Å (fixed)", $0) }
                                  ?? String(format: "adaptive (neighbour search %.3f Å)", buildCutoff)))

        var notes: [String] = []
        if frame.box == nil {
            notes.append("No box — open boundaries; atoms on the outer surface classify as “other”.")
        } else if frame.box?.isTriclinic == true {
            notes.append("Triclinic tilt is stored but not applied to the minimum image — distances near the cell edges are approximate.")
        }
        if stride > 1 {
            notes.append("Preview: every \(stride)th atom was classified; the rest are shown as “other”.")
        }

        let profile = Binning.profile(frame: frame, axis: params.profileAxis, field: crystalline,
                                      bins: params.bins, valueLabel: "crystalline fraction")
        return ToolResult(summary: summary, field: field, profile: profile,
                          scalar: crystallineFraction, notes: notes)
    }

    // MARK: - Neighbour search radius

    /// Radius for the neighbour-list build, big enough that the 14 nearest
    /// neighbours are always inside it: 1.5 × the mean 12th-neighbour distance,
    /// sampled from ~200 atoms. (In fcc the 13th/14th neighbours sit at
    /// √2 × r₁₂, so 1.5 is the smallest safe factor.)
    static func estimateBuildCutoff(frame: Frame, positions: [SIMD3<Double>],
                                    context: AnalysisContext) -> Double {
        let n = positions.count
        guard n > 1 else { return 6.0 }
        // First guess from the number density: 12 neighbours in a sphere of
        // radius r means (4/3)πr³ρ ≈ 13. Padded by 1.6 so the sample succeeds.
        var guess = 6.0
        if let volume = enclosingVolume(frame: frame, positions: positions), volume > 0 {
            let density = Double(n) / volume
            guess = 1.6 * pow(13.0 * 3.0 / (4.0 * Double.pi * density), 1.0 / 3.0)
        }
        let step = Swift.max(1, n / 200)
        for _ in 0..<4 {
            let probe = NeighborList(positions: positions, cutoff: guess, box: frame.box,
                                     isCancelled: context.isCancelled)
            if probe.wasCancelled { return guess }
            var sum = 0.0, found = 0
            for i in Swift.stride(from: 0, to: n, by: step) {
                let nearest = probe.kNearest(of: i, k: CNAClassifier.fccNeighbors)
                if nearest.count == CNAClassifier.fccNeighbors {
                    sum += nearest[CNAClassifier.fccNeighbors - 1].distance
                    found += 1
                }
            }
            if found > 0 { return 1.5 * sum / Double(found) }
            guess *= 1.6                       // too sparse to see 12 neighbours
        }
        return guess
    }

    /// Cell volume when there is a box, else the atoms' bounding box.
    private static func enclosingVolume(frame: Frame, positions: [SIMD3<Double>]) -> Double? {
        if let box = frame.box {
            let l = box.lengths
            if l.x > 0 && l.y > 0 && l.z > 0 { return l.x * l.y * l.z }
        }
        var lo = positions[0], hi = positions[0]
        for p in positions {
            lo = SIMD3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = SIMD3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        let d = hi - lo
        let volume = Swift.max(d.x, 1e-6) * Swift.max(d.y, 1e-6) * Swift.max(d.z, 1e-6)
        return volume > 0 ? volume : nil
    }
}

// MARK: - Common neighbour analysis

/// CNA signatures and their classification, with the per-atom scratch buffers
/// hoisted out of the loop (a per-atom allocation costs more than the analysis).
///
/// A signature is computed for every bond i–j of the central atom i as the
/// triplet (common neighbours, bonds among them, largest connected bond group).
/// The third index follows OVITO's definition: the number of bonds in the
/// largest connected cluster of those bonds, not a longest simple path.
final class CNAClassifier {
    /// Neighbour counts of the two adaptive tests.
    static let fccNeighbors = 12
    static let bccNeighbors = 14

    private static let maxNeighbors = 16       // the bitmasks below are UInt16
    /// (1 + √2)/2 — the classic CNA cutoff, mid-way between the first and
    /// second shells of the lattice being tested.
    private static let cutoffFactor = (1.0 + 2.0.squareRoot()) / 2.0

    private var rel = [SIMD3<Double>](repeating: .zero, count: maxNeighbors)
    private var bond = [UInt16](repeating: 0, count: maxNeighbors)
    private var parent = [Int](repeating: 0, count: maxNeighbors)
    private var groupSize = [Int](repeating: 0, count: maxNeighbors)
    private var bondA = [Int](repeating: 0, count: maxNeighbors * maxNeighbors)
    private var bondB = [Int](repeating: 0, count: maxNeighbors * maxNeighbors)

    struct Tally { var s421 = 0, s422 = 0, s444 = 0, s555 = 0, s666 = 0, other = 0 }

    /// a-CNA (Stukowski 2012). Two tests on the same atom, fcc/hcp/ico first:
    ///
    ///   r_c^{fcc} = (1+√2)/2 · ⟨r₁…r₁₂⟩
    ///   r_c^{bcc} = (1+√2)/2 · ½ · ( 2⟨r₁…r₈⟩/√3 + ⟨r₉…r₁₄⟩ )
    ///
    /// Both estimate the conventional lattice parameter from the neighbour
    /// distances and then apply the classic factor: in fcc ⟨r₁…r₁₂⟩ = a/√2 and
    /// the cutoff lands between the first and second shells; in bcc the first
    /// eight neighbours give a = 2⟨r₁…r₈⟩/√3 and the next six give a directly,
    /// and the two estimates are averaged before the same factor is applied.
    func classifyAdaptive(center: Int, neighbors: [(index: Int, distance: Double)],
                          positions: [SIMD3<Double>], box: SimulationBox?) -> StructureType {
        let count = neighbors.count
        guard count >= CNAClassifier.fccNeighbors else { return .other }

        load(center: center, indices: neighbors.lazy.map(\.index),
             limit: CNAClassifier.fccNeighbors, positions: positions, box: box)
        var sum = 0.0
        for k in 0..<CNAClassifier.fccNeighbors { sum += neighbors[k].distance }
        let rcFCC = CNAClassifier.cutoffFactor * sum / Double(CNAClassifier.fccNeighbors)
        let close = tally(count: CNAClassifier.fccNeighbors, cutoff: rcFCC)
        if close.other == 0 {
            if close.s421 == 12 { return .fcc }
            if close.s421 == 6 && close.s422 == 6 { return .hcp }
            if close.s555 == 12 { return .ico }
        }

        guard count >= CNAClassifier.bccNeighbors else { return .other }
        var first = 0.0, second = 0.0
        for k in 0..<8 { first += neighbors[k].distance }
        for k in 8..<CNAClassifier.bccNeighbors { second += neighbors[k].distance }
        let a = (2.0 * (first / 8.0) / 3.0.squareRoot() + second / 6.0) / 2.0
        let rcBCC = CNAClassifier.cutoffFactor * a
        load(center: center, indices: neighbors.lazy.map(\.index),
             limit: CNAClassifier.bccNeighbors, positions: positions, box: box)
        let wide = tally(count: CNAClassifier.bccNeighbors, cutoff: rcBCC)
        if wide.other == 0 && wide.s666 == 8 && wide.s444 == 6 { return .bcc }
        return .other
    }

    /// Conventional CNA: the bond set is everything inside a fixed cutoff. Only
    /// 12 (fcc/hcp/ico) or 14 (bcc) bonded neighbours can match a signature, so
    /// any other coordination is "other" without further work.
    func classifyConventional(center: Int, neighbors: [Int], cutoff: Double,
                              positions: [SIMD3<Double>], box: SimulationBox?) -> StructureType {
        let count = neighbors.count
        guard count == CNAClassifier.fccNeighbors || count == CNAClassifier.bccNeighbors else { return .other }
        load(center: center, indices: neighbors, limit: count, positions: positions, box: box)
        let t = tally(count: count, cutoff: cutoff)
        guard t.other == 0 else { return .other }
        if count == CNAClassifier.fccNeighbors {
            if t.s421 == 12 { return .fcc }
            if t.s421 == 6 && t.s422 == 6 { return .hcp }
            if t.s555 == 12 { return .ico }
        } else if t.s666 == 8 && t.s444 == 6 {
            return .bcc
        }
        return .other
    }

    // MARK: - Signatures

    /// Neighbour vectors relative to the central atom, minimum-imaged.
    private func load<S: Sequence>(center: Int, indices: S, limit: Int,
                                   positions: [SIMD3<Double>], box: SimulationBox?)
    where S.Element == Int {
        let origin = positions[center]
        var k = 0
        for j in indices {
            if k >= limit { break }
            var d = positions[j] - origin
            if let box { d = box.minimumImage(d) }
            rel[k] = d
            k += 1
        }
    }

    /// Counts of the five signatures of interest over the `count` bonds of the
    /// central atom, plus everything that matched none of them.
    private func tally(count: Int, cutoff: Double) -> Tally {
        let cutoffSquared = cutoff * cutoff
        for m in 0..<count { bond[m] = 0 }
        for m in 0..<count {
            for k in (m + 1)..<count {
                let d = rel[m] - rel[k]
                if d.x * d.x + d.y * d.y + d.z * d.z <= cutoffSquared {
                    bond[m] |= UInt16(1 << k)
                    bond[k] |= UInt16(1 << m)
                }
            }
        }

        var t = Tally()
        for m in 0..<count {
            let common = bond[m]                     // neighbours shared with the centre
            let commonCount = common.nonzeroBitCount

            var bondCount = 0
            for p in 0..<count where common & UInt16(1 << p) != 0 {
                var mask = bond[p] & common & ~UInt16((1 << (p + 1)) - 1)   // q > p only
                while mask != 0 {
                    let q = mask.trailingZeroBitCount
                    mask &= mask - 1
                    bondA[bondCount] = p
                    bondB[bondCount] = q
                    bondCount += 1
                }
            }

            for p in 0..<count { parent[p] = p; groupSize[p] = 0 }
            for b in 0..<bondCount { union(bondA[b], bondB[b]) }
            var longest = 0
            for b in 0..<bondCount {
                let root = find(bondA[b])
                groupSize[root] += 1
                if groupSize[root] > longest { longest = groupSize[root] }
            }

            switch (commonCount, bondCount, longest) {
            case (4, 2, 1): t.s421 += 1
            case (4, 2, 2): t.s422 += 1
            case (4, 4, 4): t.s444 += 1
            case (5, 5, 5): t.s555 += 1
            case (6, 6, 6): t.s666 += 1
            default: t.other += 1
            }
        }
        return t
    }

    private func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var walk = x
        while parent[walk] != root { let next = parent[walk]; parent[walk] = root; walk = next }
        return root
    }

    private func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}
