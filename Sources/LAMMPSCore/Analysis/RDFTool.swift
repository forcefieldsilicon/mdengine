//
//  RDFTool.swift — the radial distribution function g(r) and coordination.
//
//  g(r) is the first thing anyone asks of a disordered frame: it says whether
//  the thing is a crystal (sharp shells), a liquid (a broad first peak and a
//  real first minimum) or a gas (g ≈ 1 everywhere), and the integral under the
//  first shell is the coordination number.
//
//  The normalisation is the whole tool. A raw pair histogram is meaningless;
//  g(r) = n(r) / (N_A · ρ_B · 4πr²dr) divides out the shell volume and the
//  bulk density so that "no structure" reads exactly 1. With a cell we know ρ
//  exactly and use the minimum image; without one, the best available density
//  is the atoms' bounding box, which is an underestimate of nothing and an
//  overestimate of a sparse cluster — so the tool says so in a note rather
//  than quietly reporting a g(r) that cannot be compared to anybody else's.
//

import Foundation

public struct RDFTool: AnalysisTool {
    public static let id = "rdf"
    public static let title = "Radial distribution"
    public static let category = ToolCategory.structureOrder
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    /// A box is recommended, not required: without one the tool still runs and
    /// labels the normalisation it had to fall back to.
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    public struct Parameters: Codable, Equatable {
        /// Element of the central atoms; nil = every atom.
        public var speciesA: String?
        /// Element of the neighbours counted; nil = every atom.
        public var speciesB: String?
        /// Largest separation binned (Å). Must stay below half the shortest box
        /// edge for the minimum image to be meaningful — the tool warns if not.
        public var rMax: Double
        public var bins: Int
        /// Radius for the coordination number; nil = the first minimum of g(r)
        /// after the first peak (and the value used is reported).
        public var coordinationCutoff: Double?

        public init(speciesA: String? = nil, speciesB: String? = nil,
                    rMax: Double = 10, bins: Int = 200,
                    coordinationCutoff: Double? = nil) {
            self.speciesA = speciesA
            self.speciesB = speciesB
            self.rMax = rMax
            self.bins = bins
            self.coordinationCutoff = coordinationCutoff
        }
    }

    public static let defaultParameters = Parameters()

    /// One neighbour-list build plus one pass over every pair inside rMax.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 1.2 * Double(atoms) }

    // MARK: - Peak geometry

    /// What the histogram says about shells, once smoothed enough that Poisson
    /// noise on a thin bin cannot invent a peak.
    struct Shells {
        var firstPeakR: Double?
        var firstPeakG: Double?
        var firstMinimumR: Double?
    }

    /// Moving average over `window` bins (odd, clamped at the ends). Peaks are
    /// located on this curve and *reported* from the raw bins, so smoothing
    /// never moves a shell position.
    static func smoothed(_ g: [Double], window: Int = 5) -> [Double] {
        let half = max(0, window / 2)
        guard half > 0, g.count > window else { return g }
        return (0..<g.count).map { i in
            let lo = Swift.max(0, i - half), hi = Swift.min(g.count - 1, i + half)
            var sum = 0.0
            for k in lo...hi { sum += g[k] }
            return sum / Double(hi - lo + 1)
        }
    }

    /// First peak = the first local maximum of the smoothed curve that is a
    /// genuine excess (g ≥ 1.2) over a bin with real statistics (≥ 10 pairs).
    /// First minimum = the bottom of the valley after it: walk forward while
    /// the smoothed curve is still falling.
    static func shells(g: [Double], counts: [Int], centers: [Double]) -> Shells {
        var out = Shells()
        guard g.count > 4 else { return out }
        let s = smoothed(g)
        var peak: Int?
        for i in 2..<(g.count - 2) where s[i] >= 1.2 && counts[i] >= 10 {
            if s[i] >= s[i - 1] && s[i] >= s[i - 2] && s[i] >= s[i + 1] && s[i] >= s[i + 2] {
                peak = i
                break
            }
        }
        guard let p = peak else { return out }
        out.firstPeakR = centers[p]
        out.firstPeakG = g[p]
        var i = p
        while i + 1 < g.count && s[i + 1] <= s[i] { i += 1 }
        if i > p { out.firstMinimumR = centers[i] }
        return out
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        let n = frame.count
        guard n > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        let rMax = max(params.rMax, 1e-6)
        let bins = max(4, params.bins)
        let dr = rMax / Double(bins)

        var isA = [Bool](repeating: true, count: n)
        var isB = [Bool](repeating: true, count: n)
        if let a = params.speciesA { isA = frame.atoms.map { $0.element == a } }
        if let b = params.speciesB { isB = frame.atoms.map { $0.element == b } }
        let nA = isA.reduce(0) { $0 + ($1 ? 1 : 0) }
        let nB = isB.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard nA > 0, nB > 0 else {
            throw AnalysisError.notApplicable(
                "No atoms match speciesA “\(params.speciesA ?? "any")” / speciesB “\(params.speciesB ?? "any")”.")
        }

        var notes: [String] = []
        let volume: Double
        if let box = frame.box {
            let l = box.lengths
            volume = max(l.x * l.y * l.z, .leastNormalMagnitude)
            let shortest = [l.x, l.y, l.z].filter { $0 > 0 }.min() ?? 0
            if shortest > 0 && rMax > shortest / 2 {
                notes.append(String(format: "rMax %.3g Å exceeds half the shortest box edge (%.3g Å) — "
                                    + "the minimum image counts some pairs twice beyond that.", rMax, shortest / 2))
            }
            if box.isTriclinic { notes.append("Triclinic cell: minimum image is applied as if orthogonal.") }
        } else {
            let p = frame.positions
            var lo = p[0], hi = p[0]
            for q in p {
                lo = SIMD3(Swift.min(lo.x, q.x), Swift.min(lo.y, q.y), Swift.min(lo.z, q.z))
                hi = SIMD3(Swift.max(hi.x, q.x), Swift.max(hi.y, q.y), Swift.max(hi.z, q.z))
            }
            let e = hi - lo
            volume = max(e.x * e.y * e.z, .leastNormalMagnitude)
            notes.append("No box: g(r) is normalised by the bounding-box density "
                         + String(format: "(%.4g Å⁻³)", Double(nB) / volume)
                         + " and surface atoms are not corrected — treat the absolute scale as indicative.")
        }
        // Self-pairs: a centre is never its own neighbour, so the ideal-gas
        // count in a shell uses N_B − 1, not N_B.
        let selfPair = (params.speciesA ?? "") == (params.speciesB ?? "")
        let rhoB = Double(nB - (selfPair ? 1 : 0)) / volume

        let list = context.neighborList(for: frame, cutoff: rMax)
        if list.wasCancelled { throw AnalysisError.cancelled }

        let stride = max(1, context.stride)
        var histogram = [Int](repeating: 0, count: bins)
        var coordination = [Float](repeating: 0, count: n)
        var centres = 0

        for i in 0..<n where isA[i] && i % stride == 0 {
            if centres & 0x7FF == 0x7FF, context.isCancelled() { throw AnalysisError.cancelled }
            centres += 1
            list.forEachNeighbor(of: i) { j, d in
                guard isB[j], d < rMax else { return }
                histogram[Swift.min(bins - 1, Int(d / dr))] += 1
            }
        }
        guard centres > 0 else { throw AnalysisError.notApplicable("No central atoms after striding.") }

        var edges = [Double](repeating: 0, count: bins + 1)
        for b in 0...bins { edges[b] = Double(b) * dr }
        var g = [Double](repeating: 0, count: bins)
        var centers = [Double](repeating: 0, count: bins)
        for b in 0..<bins {
            let rLo = edges[b], rHi = edges[b + 1]
            centers[b] = (rLo + rHi) / 2
            // Exact shell volume, not 4πr²dr — the thin-shell approximation is
            // several per cent off in the first bins, where the first peak is.
            let shell = 4.0 / 3.0 * Double.pi * (rHi * rHi * rHi - rLo * rLo * rLo)
            let ideal = Double(centres) * rhoB * shell
            g[b] = ideal > 0 ? Double(histogram[b]) / ideal : 0
        }

        let shells = shells(g: g, counts: histogram, centers: centers)
        // Nothing beyond rMax was ever binned, so a larger coordination radius
        // would silently count from an incomplete shell.
        let cutoff = (params.coordinationCutoff ?? shells.firstMinimumR).map { Swift.min($0, rMax) }
        var meanCoordination = Double.nan
        if let rc = cutoff, rc > 0 {
            // A second pass, not a stored pair list: a 10 Å shell around 10⁵
            // atoms is ~10⁷ pairs, worth re-walking and not worth retaining.
            // The walk uses a list built at rc, not the rMax one — the cell
            // grid then has ~(rMax/rc)³ times more, smaller cells, which is the
            // difference between visiting ten neighbours and a thousand.
            let close = rc >= rMax * 0.9 ? list : context.neighborList(for: frame, cutoff: rc)
            if close.wasCancelled { throw AnalysisError.cancelled }
            var total = 0
            var walked = 0
            for i in 0..<n where isA[i] && i % stride == 0 {
                if walked & 0x7FF == 0x7FF, context.isCancelled() { throw AnalysisError.cancelled }
                walked += 1
                var c = 0
                close.forEachNeighbor(of: i) { j, d in if isB[j] && d <= rc { c += 1 } }
                coordination[i] = Float(c)
                total += c
            }
            meanCoordination = Double(total) / Double(centres)
        } else {
            notes.append("No first minimum found in g(r) — set coordinationCutoff to get a coordination number.")
        }

        func fmt(_ x: Double?, _ digits: Int = 3) -> String {
            guard let x, x.isFinite else { return "—" }
            return String(format: "%.\(digits)g", x)
        }
        var summary: [SummaryRow] = [
            SummaryRow("Pair", "\(params.speciesA ?? "all")–\(params.speciesB ?? "all")"),
            SummaryRow("First peak", fmt(shells.firstPeakR, 4), unit: "Å"),
            SummaryRow("g at first peak", fmt(shells.firstPeakG)),
            SummaryRow("First minimum", fmt(shells.firstMinimumR, 4), unit: "Å"),
            SummaryRow("Coordination cutoff", fmt(cutoff, 4)
                       + (params.coordinationCutoff == nil ? " (first minimum)" : ""), unit: "Å"),
            SummaryRow("Mean coordination", fmt(meanCoordination)),
            SummaryRow("Number density ρ", String(format: "%.4g", rhoB), unit: "Å⁻³"),
            SummaryRow("Centres × neighbours", "\(centres) × \(nB)")
        ]
        if stride > 1 {
            summary.append(SummaryRow("Sampling", "1/\(stride) of A atoms as centres"))
            notes.append("Preview: 1/\(stride) of the A atoms are used as centres; "
                         + "g(r) is normalised by that count, so the curve is unbiased but noisier.")
        }

        let profile = Profile(axisLabel: "r (Å)", valueLabel: "g(r)",
                              edges: edges, values: g, counts: histogram)
        let hiColour = Float(max(meanCoordination.isFinite ? meanCoordination * 1.5 : 12, 1))
        let field = PerAtomField(name: "coordination", values: coordination,
                                 palette: .continuous(min: 0, max: hiColour, colormapName: "viridis"),
                                 legendTitle: "Coordination")
        return ToolResult(summary: summary, field: field, profile: profile,
                          scalar: shells.firstPeakR, notes: notes)
    }
}
