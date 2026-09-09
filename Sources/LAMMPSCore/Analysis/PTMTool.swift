//
//  PTMTool.swift — polyhedral template matching: structure, lattice
//  orientation, grain boundaries.
//
//  Design §2.1, phase 5. a-CNA (`CrystallinityTool`) answers "what structure is
//  this atom in" from bond topology, which is cheap but brittle once thermal
//  displacement starts flipping bonds across the cutoff. PTM (Larsen, Schmidt &
//  Schiøtz 2016) instead fits ideal neighbour shells by least squares: the
//  answer is an RMSD, which degrades smoothly with temperature instead of
//  falling off a cliff, and it comes with the thing a-CNA cannot give — the
//  *orientation* of the local lattice. Orientation is what turns "these atoms
//  are fcc" into "these atoms are two grains meeting at 15°".
//
//  The correspondence search lives in `TemplateMatching.swift`; the quaternion
//  algebra and the symmetry groups in `Quaternion.swift`.
//

import Foundation

/// Structure classes PTM can report. The first five share their raw values,
/// labels and colours with `StructureType` so a PTM figure and an a-CNA figure
/// are the same picture; simple cubic is PTM-only and gets its own slot.
public enum PTMClass: Int, CaseIterable {
    case other = 0, fcc, hcp, bcc, ico, sc

    public var structureType: StructureType? { StructureType(rawValue: rawValue) }
    public var label: String { structureType?.label ?? "Simple cubic" }
    public var color: RGB { structureType?.color ?? RGB(0.25, 0.8, 0.85) }
}

public struct PTMTool: AnalysisTool {
    public static let id = "ptm"
    public static let title = "PTM (orientation & grains)"
    public static let category = ToolCategory.structureOrder
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    /// Local, like CNA: a box is used for the minimum image when present, and
    /// without one the outer surface honestly fails to match any template.
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    public struct Parameters: Codable, Equatable {
        /// "structure", "orientation", "rmsd", "gb" or "shear".
        public var quantity: String
        /// Dimensionless RMSD (both point sets at unit mean neighbour length)
        /// above which an atom is "other". 0.1 is the value the paper and OVITO
        /// both default to.
        public var rmsdThreshold: Double
        /// Disorientation (degrees) between neighbouring same-type atoms that
        /// counts as a grain boundary.
        public var gbAngle: Double
        public var profileAxis: Axis
        public var bins: Int
        /// Candidate templates: any of fcc, hcp, bcc, ico, sc.
        public var templates: [String]

        public init(quantity: String = "structure", rmsdThreshold: Double = 0.1,
                    gbAngle: Double = 5.0, profileAxis: Axis = .z, bins: Int = 24,
                    templates: [String] = ["fcc", "hcp", "bcc", "ico"]) {
            self.quantity = quantity
            self.rmsdThreshold = rmsdThreshold
            self.gbAngle = gbAngle
            self.profileAxis = profileAxis
            self.bins = bins
            self.templates = templates
        }
    }

    public static let defaultParameters = Parameters()

    /// Measured on a 6³ Al block, release, Apple silicon: 25 µs/atom on a
    /// *perfect* lattice (the exact-match exit below stops after one template)
    /// and ~55 µs per atom per template once the search really runs on every
    /// candidate — so ~220 µs/atom for the default four. This is the honest
    /// price of skipping the paper's canonical-form lookup; the governor is
    /// meant to defer the tool during playback on that basis.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double {
        55.0 * Double(atoms) * Double(max(1, params.templates.count))
    }

    /// Clusters below this many atoms are not counted as grains — a lone atom
    /// that happens to match fcc inside a melt is not a crystallite.
    static let minimumGrainSize = 4

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        let n = frame.count
        guard n > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        let templates = params.templates.compactMap { PTMTemplate.named($0) }
        guard !templates.isEmpty else {
            throw AnalysisError.notApplicable("No known template in \(params.templates).")
        }
        if context.isCancelled() { throw AnalysisError.cancelled }

        let positions = frame.positions
        let maxVertices = templates.map(\.count).max() ?? 12
        let cutoff = CrystallinityTool.estimateBuildCutoff(frame: frame, positions: positions,
                                                           context: context)
        let list = context.neighborList(for: frame, cutoff: cutoff)
        if list.wasCancelled || context.isCancelled() { throw AnalysisError.cancelled }

        let stride = max(1, context.stride)
        var classes = [PTMClass](repeating: .other, count: n)
        var rmsd = [Double](repeating: .nan, count: n)
        var shear = [Double](repeating: 0, count: n)
        var orientation = [Quat](repeating: .identity, count: n)

        let matcher = TemplateMatcher()
        var relative = [SIMD3<Double>](repeating: .zero, count: maxVertices)
        var lengths = [Double](repeating: 0, count: maxVertices)
        var scaled = [SIMD3<Double>](repeating: .zero, count: maxVertices)

        for i in Swift.stride(from: 0, to: n, by: stride) {
            if i % 1_024 == 0, context.isCancelled() { throw AnalysisError.cancelled }
            let nearest = list.kNearest(of: i, k: maxVertices)
            let found = nearest.count
            let origin = positions[i]
            for k in 0..<found {
                var d = positions[nearest[k].index] - origin
                if let box = frame.box { d = box.minimumImage(d) }
                relative[k] = d
                lengths[k] = nearest[k].distance
            }

            var best: PTMMatch?
            var bestTemplate: PTMTemplate?
            for template in templates where template.count <= found {
                let m = template.count
                var mean = 0.0
                for k in 0..<m { mean += lengths[k] }
                mean /= Double(m)
                guard mean > 1e-9 else { continue }
                for k in 0..<m { scaled[k] = relative[k] / mean }
                guard let candidate = matcher.match(observed: scaled, template: template) else { continue }
                if candidate.rmsd < (best?.rmsd ?? .infinity) { best = candidate; bestTemplate = template }
                // An exact fit cannot be beaten, only tied: a defect-free
                // lattice pays for one template instead of four.
                if candidate.rmsd < 1e-9 { break }
            }

            guard let match = best, let template = bestTemplate else { continue }
            rmsd[i] = match.rmsd
            if match.rmsd < params.rmsdThreshold {
                classes[i] = template.structure
                orientation[i] = match.orientation
                shear[i] = match.deformation.greenLagrangianStrain.vonMisesShear
            }
        }
        if context.isCancelled() { throw AnalysisError.cancelled }

        // MARK: Grains and grain boundaries

        let gbRadians = params.gbAngle * Double.pi / 180
        var isGrainBoundary = [Bool](repeating: false, count: n)
        var parent = Array(0..<n)
        func find(_ a: Int) -> Int {
            var root = a
            while parent[root] != root { root = parent[root] }
            var walk = a
            while parent[walk] != root { let next = parent[walk]; parent[walk] = root; walk = next }
            return root
        }
        var gbSum = 0.0, gbPairs = 0

        // The comparison runs over every neighbour inside the structure-search
        // radius, not just the template's own vertices. That is deliberate: at a
        // sharp boundary the atoms *on* the interface match nothing, so the last
        // matched atom of one grain and the first of the other are two shells
        // apart, and a 12-nearest test would look straight past the boundary it
        // is supposed to find.
        for i in Swift.stride(from: 0, to: n, by: stride) where classes[i] != .other {
            if i % 1_024 == 0, context.isCancelled() { throw AnalysisError.cancelled }
            let symmetry = symmetry(of: classes[i])
            list.forEachNeighbor(of: i) { j, _ in
                guard j % stride == 0, classes[j] == classes[i] else { return }
                let angle = LatticeSymmetry.disorientation(orientation[i], orientation[j],
                                                           symmetry: symmetry)
                if angle > gbRadians {
                    isGrainBoundary[i] = true
                    if j > i { gbSum += angle; gbPairs += 1 }
                } else if find(i) != find(j) {
                    parent[find(j)] = find(i)
                }
            }
        }

        var grainSize = [Int: Int]()
        for i in Swift.stride(from: 0, to: n, by: stride) where classes[i] != .other {
            grainSize[find(i), default: 0] += 1
        }
        let grains = grainSize.values.filter { $0 >= minimumGrainSize }.count

        // MARK: Statistics

        var counts = [Int](repeating: 0, count: PTMClass.allCases.count)
        var sampled = 0, matched = 0, gbAtoms = 0
        var rmsdSum = 0.0
        for i in Swift.stride(from: 0, to: n, by: stride) {
            sampled += 1
            counts[classes[i].rawValue] += 1
            if classes[i] != .other { matched += 1; rmsdSum += rmsd[i] }
            if isGrainBoundary[i] { gbAtoms += 1 }
        }
        let inverse = 1.0 / Double(max(1, sampled))
        let crystalline = Double(matched) * inverse
        let meanRMSD = matched > 0 ? rmsdSum / Double(matched) : 0
        let gbFraction = Double(gbAtoms) * inverse
        let meanGBAngle = gbPairs > 0 ? gbSum / Double(gbPairs) * 180 / Double.pi : 0

        // MARK: Output

        let requested = Set(params.templates.compactMap { PTMTemplate.named($0)?.structure })
        func percent(_ x: Double) -> String { String(format: "%.1f", x * 100) }
        var summary: [SummaryRow] = PTMClass.allCases
            .filter { $0 == .other || requested.contains($0) }
            .map { SummaryRow($0.label, percent(Double(counts[$0.rawValue]) * inverse), unit: "%") }
        summary.append(SummaryRow("Crystalline fraction", percent(crystalline), unit: "%"))
        summary.append(SummaryRow("Mean RMSD (matched)", String(format: "%.4f", meanRMSD)))
        summary.append(SummaryRow("Grain-boundary fraction", percent(gbFraction), unit: "%"))
        summary.append(SummaryRow("Grains", String(grains)))
        summary.append(SummaryRow("Mean disorientation at GB", String(format: "%.2f", meanGBAngle), unit: "°"))
        summary.append(SummaryRow("Method", "PTM, RMSD < \(String(format: "%.3f", params.rmsdThreshold)),"
                                  + " GB > \(String(format: "%.1f", params.gbAngle))°"))

        var notes = ["Polyhedral template matching (Larsen 2016) without the Weinberg"
                     + " canonical-form acceleration: the correspondence is seeded from the two"
                     + " nearest neighbours and refined, so the answer is the paper's but the"
                     + " cost is higher.",
                     "Grains are connected clusters of same-type atoms whose neighbour"
                     + " disorientation stays under \(String(format: "%.1f", params.gbAngle))°;"
                     + " clusters below \(minimumGrainSize) atoms are not counted."]
        if frame.box == nil {
            notes.append("No box — open boundaries; surface atoms match no template and count as “other”.")
        } else if frame.box?.isTriclinic == true {
            notes.append("Triclinic tilt is stored but not applied to the minimum image — distances near the cell edges are approximate.")
        }
        if stride > 1 {
            notes.append("Preview: every \(stride)th atom was matched; the rest are shown as “other” and take no part in the grain analysis.")
        }

        let (field, fieldNote) = makeField(quantity: params.quantity, count: n, stride: stride,
                                           classes: classes, rmsd: rmsd, shear: shear,
                                           orientation: orientation, isGrainBoundary: isGrainBoundary,
                                           threshold: params.rmsdThreshold)
        if let fieldNote { notes.append(fieldNote) }

        let crystallineField: [Float] = (0..<n).map { i in
            i % stride == 0 && classes[i] != .other ? 1 : 0
        }
        let profile = Binning.profile(frame: frame, axis: params.profileAxis, field: crystallineField,
                                      bins: params.bins, valueLabel: "crystalline fraction")
        return ToolResult(summary: summary, field: field, profile: profile,
                          scalar: crystalline, notes: notes)
    }

    static func symmetry(of c: PTMClass) -> LatticeSymmetry {
        switch c {
        case .fcc, .bcc, .sc: return .cubic
        case .hcp: return .hexagonal
        case .ico, .other: return .none
        }
    }

    // MARK: - Per-atom field

    private static func makeField(quantity: String, count n: Int, stride: Int,
                                  classes: [PTMClass], rmsd: [Double], shear: [Double],
                                  orientation: [Quat], isGrainBoundary: [Bool],
                                  threshold: Double) -> (PerAtomField, String?) {
        switch quantity.lowercased() {
        case "orientation":
            let values: [Float] = (0..<n).map { i in
                switch classes[i] {
                case .fcc, .bcc, .sc: return cubicIPFHue(orientation[i])
                case .hcp: return hcpTiltHue(orientation[i])
                default: return 0
                }
            }
            let note = "Orientation is shown as a hue in 0…1, not as a colour triple: for cubic"
                     + " atoms it is the inverse-pole-figure hue of the crystal direction parallel"
                     + " to the lab z axis (0 = red = ⟨001⟩, ⅓ = green = ⟨101⟩, ⅔ = blue = ⟨111⟩,"
                     + " barycentric in the standard triangle); for hcp it is the simpler c-axis"
                     + " tilt, 0 = c ∥ z, 1 = c ⟂ z. Unmatched and icosahedral atoms read 0."
            return (PerAtomField(name: "orientation_hue", values: values,
                                 palette: .continuous(min: 0, max: 1, colormapName: "viridis"),
                                 legendTitle: "Lattice orientation (IPF hue)"), note)
        case "rmsd":
            let values: [Float] = (0..<n).map { i in
                guard i % stride == 0, rmsd[i].isFinite else { return Float(threshold) }
                return Float(min(rmsd[i], threshold))
            }
            return (PerAtomField(name: "ptm_rmsd", values: values,
                                 palette: .continuous(min: 0, max: Float(threshold), colormapName: "inferno"),
                                 legendTitle: "PTM RMSD"),
                    "Atoms that matched no template are clamped to the top of the ramp.")
        case "gb":
            let values: [Float] = (0..<n).map { isGrainBoundary[$0] ? 1 : 0 }
            return (PerAtomField(name: "grain_boundary", values: values,
                                 palette: .categorical([("Interior", RGB(0.6, 0.6, 0.6)),
                                                        ("Grain boundary", RGB(1.0, 0.55, 0.1))]),
                                 legendTitle: "Grain boundaries"), nil)
        case "shear":
            let values: [Float] = (0..<n).map { Float(shear[$0]) }
            return (PerAtomField(name: "von_mises_shear", values: values,
                                 palette: .continuous(min: 0, max: 0.2, colormapName: "inferno"),
                                 legendTitle: "Von Mises shear"),
                    "Shear is the von Mises invariant of ½(FᵀF − I) for the affine fit of the"
                    + " template onto the neighbourhood; both sides carry unit mean neighbour"
                    + " length, so this is the deviatoric part only.")
        default:
            let values: [Float] = classes.map { Float($0.rawValue) }
            let note = quantity.lowercased() == "structure" ? nil
                     : "Unknown quantity “\(quantity)” — showing the structure field."
            return (PerAtomField(name: "structure", values: values,
                                 palette: .categorical(PTMClass.allCases.map { ($0.label, $0.color) }),
                                 legendTitle: "Structure (PTM)"), note)
        }
    }

    /// Inverse-pole-figure hue for a cubic lattice: which crystal direction is
    /// parallel to the lab z axis, folded into the standard ⟨001⟩–⟨101⟩–⟨111⟩
    /// triangle and coloured by barycentric weight, then reduced to its hue.
    static func cubicIPFHue(_ q: Quat) -> Float {
        let d = q.conjugate.rotate(SIMD3(0, 0, 1))
        var c = [abs(d.x), abs(d.y), abs(d.z)]
        c.sort()                                        // h ≤ k ≤ l
        let (h, k, l) = (c[0], c[1], c[2])
        var rgb = SIMD3(l - k, (k - h) * 2.0.squareRoot(), h * 3.0.squareRoot())
        let peak = max(rgb.x, max(rgb.y, rgb.z))
        guard peak > 1e-9 else { return 0 }
        rgb /= peak
        return hue(rgb)
    }

    /// hcp has no ⟨001⟩/⟨101⟩/⟨111⟩ triangle to fall back on, so the simpler
    /// scheme: the tilt of the c axis away from lab z, 0…90° mapped to 0…1.
    static func hcpTiltHue(_ q: Quat) -> Float {
        let c = q.rotate(SIMD3(0, 0, 1))
        let tilt = acos(min(1, abs(c.z)))
        return Float(tilt / (Double.pi / 2))
    }

    /// HSV hue of an RGB triple, in 0…1. Pure red is 0, green ⅓, blue ⅔.
    private static func hue(_ rgb: SIMD3<Double>) -> Float {
        let mx = max(rgb.x, max(rgb.y, rgb.z)), mn = min(rgb.x, min(rgb.y, rgb.z))
        let chroma = mx - mn
        guard chroma > 1e-9 else { return 0 }
        var h: Double
        if mx == rgb.x { h = (rgb.y - rgb.z) / chroma }
        else if mx == rgb.y { h = 2 + (rgb.z - rgb.x) / chroma }
        else { h = 4 + (rgb.x - rgb.y) / chroma }
        h /= 6
        if h < 0 { h += 1 }
        return Float(min(1, max(0, h)))
    }
}
