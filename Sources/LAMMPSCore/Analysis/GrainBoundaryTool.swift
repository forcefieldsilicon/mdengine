//
//  GrainBoundaryTool.swift — grain-level answers from PTM orientations.
//
//  `PTMTool` answers "what structure is this atom in, and how is its lattice
//  turned"; grains are one row of its summary. The question a user actually
//  arrives with after a deposition or an anneal is the grain question: how many
//  grains, how big, how much of the solid is boundary, and what misorientations
//  those boundaries carry. That is this tool. The segmentation itself is shared
//  with PTM (`GrainSegmentation`) so the two can never disagree (GJOB-235).
//

import Foundation

public struct GrainBoundaryTool: AnalysisTool {
    public static let id = "grains"
    public static let title = "Grain boundaries"
    public static let category = ToolCategory.structureOrder
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    /// Like PTM: a box is used for the minimum image when there is one, and
    /// without one the outer surface honestly matches no template.
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    public struct Parameters: Codable, Equatable {
        /// "grain" (grain id, 0 = boundary/unassigned), "gb" (1 on boundary
        /// atoms) or "misorientation" (degrees).
        public var quantity: String
        /// Disorientation (degrees) between neighbouring same-structure atoms
        /// that counts as a grain boundary. 5° is the usual low-angle cut.
        public var gbAngle: Double
        /// Clusters below this many atoms are not counted as grains.
        public var minimumGrainSize: Int
        /// PTM RMSD above which an atom matches nothing and takes no part in the
        /// grain analysis.
        public var rmsdThreshold: Double
        /// Which lattice the grains are made of: "any", "fcc", "bcc" or "hcp".
        public var structure: String
        /// "misorientation" for the misorientation distribution, or "x"/"y"/"z"
        /// for grain-boundary fraction along that axis.
        public var profileAxis: String
        public var bins: Int

        public init(quantity: String = "grain", gbAngle: Double = 5.0,
                    minimumGrainSize: Int = 4, rmsdThreshold: Double = 0.1,
                    structure: String = "any", profileAxis: String = "misorientation",
                    bins: Int = 18) {
            self.quantity = quantity
            self.gbAngle = gbAngle
            self.minimumGrainSize = minimumGrainSize
            self.rmsdThreshold = rmsdThreshold
            self.structure = structure
            self.profileAxis = profileAxis
            self.bins = bins
        }
    }

    public static let defaultParameters = Parameters()

    /// The cost is PTM's match loop; the segmentation on top is a neighbour
    /// sweep and disappears next to it. One template when the structure is
    /// named, three when it is not.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double {
        55.0 * Double(atoms) * Double(templateNames(for: params.structure).count)
    }

    /// Which PTM templates a structure filter asks for. "any" keeps the three
    /// lattices that have a meaningful orientation; icosahedral clusters have no
    /// lattice to turn, so they are never grain material.
    static func templateNames(for structure: String) -> [String] {
        switch structure.lowercased() {
        case "fcc": return ["fcc"]
        case "bcc": return ["bcc"]
        case "hcp": return ["hcp"]
        default: return ["fcc", "hcp", "bcc"]
        }
    }

    /// Largest possible disorientation for a symmetry class, in degrees — the
    /// top of the misorientation histogram. 62.8° is the cubic (Mackenzie)
    /// limit; 93.8° the hexagonal one.
    static func maximumDisorientation(_ symmetry: LatticeSymmetry) -> Double {
        switch symmetry {
        case .cubic: return 62.8
        case .hexagonal: return 93.8
        case .none: return 180.0
        }
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        let n = frame.count
        guard n > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        let names = templateNames(for: params.structure)
        let templates = names.compactMap { PTMTemplate.named($0) }
        guard !templates.isEmpty else {
            throw AnalysisError.notApplicable("Unknown structure “\(params.structure)” — use any, fcc, bcc or hcp.")
        }
        if context.isCancelled() { throw AnalysisError.cancelled }

        let stride = max(1, context.stride)
        let match = try PTMTool.classify(frame: frame, context: context, templates: templates,
                                         rmsdThreshold: params.rmsdThreshold)
        let classes = match.classes
        let gbRadians = params.gbAngle * Double.pi / 180
        let minimumGrainSize = max(1, params.minimumGrainSize)
        let segmentation = try GrainSegmentation.compute(count: n, stride: stride, classes: classes,
                                                         orientation: match.orientation,
                                                         neighbors: match.neighbors,
                                                         gbRadians: gbRadians,
                                                         isCancelled: context.isCancelled)

        // MARK: Grains — clusters, then the boundaries between them
        //
        // A sharp high-angle boundary is a layer of atoms that match no
        // template at all, so the two crystals never see each other: PTM's
        // neighbour test (`segmentation.isBoundary`) finds the *low*-angle case
        // and nothing else. The grain question needs both, so on top of the
        // clusters this walks the contacts between them — an atom bridging two
        // clusters is a boundary atom, and the angle it sits on is the
        // disorientation between the two clusters it bridges.

        let roots = segmentation.grainRoots(minimumSize: minimumGrainSize)
        var labelOfRoot = [Int: Int]()
        for (k, r) in roots.enumerated() { labelOfRoot[r] = k + 1 }
        let clusters = roots.count
        var cluster = [Int](repeating: 0, count: n)          // 0 = no grain material
        for i in Swift.stride(from: 0, to: n, by: stride) where classes[i] != .other {
            if let label = labelOfRoot[segmentation.root[i]] { cluster[i] = label }
        }

        // One orientation per cluster: the root atom's. Every atom in a cluster
        // is within `gbAngle` of its neighbours by construction, so any member
        // is a fair representative of the whole.
        var clusterOrientation = [Quat](repeating: .identity, count: clusters + 1)
        var clusterSymmetry = [LatticeSymmetry](repeating: .cubic, count: clusters + 1)
        for (k, r) in roots.enumerated() {
            clusterOrientation[k + 1] = match.orientation[r]
            clusterSymmetry[k + 1] = PTMTool.symmetry(of: classes[r])
        }
        func disorientation(_ g: Int, _ h: Int) -> Double {
            let symmetry = clusterSymmetry[g] == clusterSymmetry[h] ? clusterSymmetry[g] : .none
            return LatticeSymmetry.disorientation(clusterOrientation[g], clusterOrientation[h],
                                                  symmetry: symmetry)
        }

        /// The cluster pairs atom `i` bridges: its own cluster against each
        /// neighbouring one, or — for an atom that is not grain material — every
        /// pair of clusters it touches at once.
        func contacts(of i: Int) -> [(Int, Int)] {
            var others: [Int] = []
            match.neighbors.forEachNeighbor(of: i) { j, _ in
                guard j % stride == 0 else { return }
                let label = cluster[j]
                guard label > 0, label != cluster[i], !others.contains(label) else { return }
                others.append(label)
            }
            if cluster[i] > 0 { return others.map { (Swift.min(cluster[i], $0), Swift.max(cluster[i], $0)) } }
            guard others.count > 1 else { return [] }
            let sorted = others.sorted()
            return sorted.indices.dropLast().flatMap { x in sorted[(x + 1)...].map { (sorted[x], $0) } }
        }

        // Clusters that touch across less than `gbAngle` are one grain that a
        // defect layer happened to cut in two; merge them before counting.
        var grainOf = Array(0...clusters)
        func find(_ a: Int) -> Int {
            var root = a
            while grainOf[root] != root { root = grainOf[root] }
            return root
        }
        var pairAngle = [Int: Double]()
        for i in Swift.stride(from: 0, to: n, by: stride) {
            if i % 1_024 == 0, context.isCancelled() { throw AnalysisError.cancelled }
            for (g, h) in contacts(of: i) {
                let key = g * (clusters + 1) + h
                let angle = pairAngle[key] ?? disorientation(g, h)
                pairAngle[key] = angle
                if angle <= gbRadians, find(g) != find(h) { grainOf[find(h)] = find(g) }
            }
        }

        // Final grain ids: 1…K in size order, 0 for boundary and unassigned.
        var atomsInGroup = [Int: Int]()
        for label in 1...Swift.max(1, clusters) where label <= clusters {
            atomsInGroup[find(label), default: 0] += segmentation.clusterSize[roots[label - 1]] ?? 0
        }
        let ordered = atomsInGroup.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var idOfGroup = [Int: Int]()
        for (k, entry) in ordered.enumerated() { idOfGroup[entry.key] = k + 1 }
        var grainId = [Int](repeating: 0, count: n)
        for i in Swift.stride(from: 0, to: n, by: stride) where cluster[i] > 0 {
            grainId[i] = idOfGroup[find(cluster[i])] ?? 0
        }
        let sizes = ordered.map(\.value)
        let grains = sizes.count

        // Boundary atoms and the angles they carry.
        var isBoundary = segmentation.isBoundary
        var atomAngle = [Double](repeating: .nan, count: n)
        var boundaryAngles: [Double] = []
        for i in Swift.stride(from: 0, to: n, by: stride) {
            if i % 1_024 == 0, context.isCancelled() { throw AnalysisError.cancelled }
            var seen = Set<Int>()
            for (g, h) in contacts(of: i) {
                let (a, b) = (idOfGroup[find(g)] ?? 0, idOfGroup[find(h)] ?? 0)
                guard a != b, a > 0, b > 0 else { continue }
                let angle = pairAngle[g * (clusters + 1) + h] ?? disorientation(g, h)
                isBoundary[i] = true
                if !(atomAngle[i] >= angle) { atomAngle[i] = angle }
                if seen.insert(Swift.min(a, b) * (grains + 1) + Swift.max(a, b)).inserted {
                    boundaryAngles.append(angle)
                }
            }
            if !isBoundary[i] { atomAngle[i] = segmentation.maxMisorientation[i] }
            if isBoundary[i], atomAngle[i].isNaN { atomAngle[i] = segmentation.maxMisorientation[i] }
            if isBoundary[i] { grainId[i] = 0 }
        }

        // MARK: Statistics

        var sampled = 0, matched = 0, boundaryAtoms = 0
        var classCount = [Int](repeating: 0, count: PTMClass.allCases.count)
        for i in Swift.stride(from: 0, to: n, by: stride) {
            sampled += 1
            classCount[classes[i].rawValue] += 1
            if classes[i] != .other { matched += 1 }
            if isBoundary[i] { boundaryAtoms += 1 }
        }
        let inverse = 1.0 / Double(max(1, sampled))
        let boundaryFraction = Double(boundaryAtoms) * inverse
        let meanSize = sizes.isEmpty ? 0 : Double(sizes.reduce(0, +)) / Double(sizes.count)
        let medianSize = median(sizes.map(Double.init))
        let meanAngle = boundaryAngles.isEmpty ? 0
            : boundaryAngles.reduce(0, +) / Double(boundaryAngles.count) * 180 / Double.pi

        // Equivalent spherical diameter: the grain's share of the cell volume,
        // read as a sphere. Needs a box to have a volume at all.
        let volumePerAtom: Double? = frame.box.map { box in
            let l = box.lengths
            return l.x * l.y * l.z / Double(max(1, n))
        }
        func diameter(_ atoms: Double) -> Double {
            guard let v = volumePerAtom, v > 0, atoms > 0 else { return 0 }
            return 2 * pow(3 * atoms * v / (4 * Double.pi), 1.0 / 3.0)
        }

        // The symmetry the histogram is scaled to: whatever the matched atoms
        // mostly are.
        let dominant = PTMClass.allCases
            .filter { $0 != .other }
            .max { classCount[$0.rawValue] < classCount[$1.rawValue] } ?? .fcc
        let symmetry = PTMTool.symmetry(of: matched > 0 ? dominant : .fcc)

        // MARK: Output

        func percent(_ x: Double) -> String { String(format: "%.1f", x * 100) }
        var summary: [SummaryRow] = [
            SummaryRow("Grains", String(grains)),
            SummaryRow("Grain-boundary atoms", percent(boundaryFraction), unit: "%"),
            SummaryRow("Crystalline fraction", percent(Double(matched) * inverse), unit: "%"),
            SummaryRow("Mean grain size", String(format: "%.0f", meanSize), unit: "atoms"),
            SummaryRow("Median grain size", String(format: "%.0f", medianSize), unit: "atoms"),
        ]
        if volumePerAtom != nil {
            summary.append(SummaryRow("Mean grain diameter", String(format: "%.1f", diameter(meanSize)), unit: "Å"))
            summary.append(SummaryRow("Median grain diameter", String(format: "%.1f", diameter(medianSize)), unit: "Å"))
        }
        summary.append(SummaryRow("Mean misorientation at GB", String(format: "%.2f", meanAngle), unit: "°"))
        summary.append(SummaryRow("Boundary pairs", String(boundaryAngles.count)))
        summary.append(SummaryRow("Method", "PTM \(names.joined(separator: "/")), RMSD < "
                                  + "\(String(format: "%.3f", params.rmsdThreshold)), GB > "
                                  + "\(String(format: "%.1f", params.gbAngle))°, grain ≥ \(minimumGrainSize) atoms"))

        var notes = ["Grains are connected clusters of same-structure atoms whose neighbour"
                     + " disorientation stays under \(String(format: "%.1f", params.gbAngle))°;"
                     + " clusters below \(minimumGrainSize) atoms are not counted. Orientations come"
                     + " from polyhedral template matching (Larsen 2016), the same code PTM uses.",
                     "A boundary atom is one that touches two grains at once — at a sharp"
                     + " high-angle boundary the interface atoms match no template, so the two"
                     + " crystals are found through them rather than by comparing them directly."
                     + " Clusters that meet at less than \(String(format: "%.1f", params.gbAngle))°"
                     + " are merged: a defect layer inside one crystal is not a grain boundary."]
        if volumePerAtom != nil {
            notes.append("Equivalent spherical diameter assumes every atom owns the same share of the"
                         + " cell volume — with a large vacuum or gas region in the box it is an"
                         + " overestimate.")
        } else {
            notes.append("No box — open boundaries: surface atoms match no template, and there is no"
                         + " volume, so no grain diameter.")
        }
        if frame.box?.isTriclinic == true {
            notes.append("Triclinic tilt is stored but not applied to the minimum image — distances near the cell edges are approximate.")
        }
        if stride > 1 {
            notes.append("Preview: every \(stride)th atom was matched; the rest take no part in the grain analysis.")
        }

        let (field, fieldNote) = makeField(quantity: params.quantity, count: n,
                                           grainId: grainId, grainCount: grains,
                                           isBoundary: isBoundary, misorientation: atomAngle,
                                           symmetry: symmetry)
        if let fieldNote { notes.append(fieldNote) }

        let (profile, profileNote) = makeProfile(params: params, frame: frame,
                                                 isBoundary: isBoundary, angles: boundaryAngles,
                                                 symmetry: symmetry)
        if let profileNote { notes.append(profileNote) }

        return ToolResult(summary: summary, field: field, profile: profile,
                          scalar: Double(grains), notes: notes)
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    // MARK: - Per-atom field

    private static func makeField(quantity: String, count n: Int,
                                  grainId: [Int], grainCount: Int, isBoundary: [Bool],
                                  misorientation: [Double],
                                  symmetry: LatticeSymmetry) -> (PerAtomField, String?) {
        switch quantity.lowercased() {
        case "gb":
            let values: [Float] = (0..<n).map { isBoundary[$0] ? 1 : 0 }
            return (PerAtomField(name: "grain_boundary", values: values,
                                 palette: .categorical([("Interior", RGB(0.6, 0.6, 0.6)),
                                                        ("Grain boundary", RGB(1.0, 0.55, 0.1))]),
                                 legendTitle: "Grain boundaries"), nil)
        case "misorientation":
            let degrees: [Float] = (0..<n).map { i in
                let a = misorientation[i]
                return a.isFinite ? Float(a * 180 / Double.pi) : 0
            }
            let top = max(1, Float(maximumDisorientation(symmetry)))
            return (PerAtomField(name: "misorientation", values: degrees,
                                 palette: .continuous(min: 0, max: top, colormapName: "inferno"),
                                 legendTitle: "Misorientation (°)"),
                    "Misorientation is the largest disorientation to any same-structure neighbour,"
                    + " so an interior atom reads ~0 and a boundary atom carries the angle of the"
                    + " boundary it sits on. Unmatched atoms read 0.")
        default:
            let values: [Float] = grainId.map(Float.init)
            let note = quantity.lowercased() == "grain" ? nil
                     : "Unknown quantity “\(quantity)” — showing the grain field."
            if grainCount <= 23 {
                var entries: [(String, RGB)] = [("Boundary / unassigned", RGB(0.45, 0.45, 0.45))]
                for k in 1...max(1, grainCount) { entries.append(("Grain \(k)", grainColor(k))) }
                return (PerAtomField(name: "grain", values: values,
                                     palette: .categorical(entries),
                                     legendTitle: "Grain"), note)
            }
            return (PerAtomField(name: "grain", values: values,
                                 palette: .continuous(min: 0, max: Float(grainCount),
                                                      colormapName: "viridis"),
                                 legendTitle: "Grain (\(grainCount) grains)"),
                    note ?? "Too many grains for a legend — the id is shown as a ramp; 0 is boundary.")
        }
    }

    /// Distinct colours for neighbouring grain ids: hue by the golden angle, so
    /// grain k and grain k+1 never look alike.
    static func grainColor(_ k: Int) -> RGB {
        let hue = Double(k) * 0.61803398875
        let h = (hue - hue.rounded(.down)) * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        // Lifted off full saturation so the colours read on a dark background.
        return RGB(Float(0.25 + 0.7 * r), Float(0.25 + 0.7 * g), Float(0.25 + 0.7 * b))
    }

    // MARK: - Profile

    private static func makeProfile(params: Parameters, frame: Frame,
                                    isBoundary: [Bool], angles: [Double],
                                    symmetry: LatticeSymmetry) -> (Profile, String?) {
        let bins = max(1, params.bins)
        let axis = params.profileAxis.lowercased()
        if let axis = Axis(rawValue: axis) {
            let field: [Float] = isBoundary.map { $0 ? 1 : 0 }
            return (Binning.profile(frame: frame, axis: axis, field: field, bins: bins,
                                    valueLabel: "grain-boundary fraction"), nil)
        }

        // Misorientation distribution: one entry per boundary pair, on a fixed
        // 0…max range so two frames of the same material are comparable.
        let top = maximumDisorientation(symmetry)
        let width = top / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for a in angles {
            let degrees = a * 180 / Double.pi
            let b = min(bins - 1, max(0, Int(degrees / width)))
            counts[b] += 1
        }
        let edges = (0...bins).map { Double($0) * width }
        let profile = Profile(axisLabel: "misorientation (°)", valueLabel: "boundary pairs",
                              edges: edges, values: counts.map(Double.init), counts: counts)
        let note = axis == "misorientation" ? nil
                 : "Unknown profileAxis “\(params.profileAxis)” — showing the misorientation"
                   + " distribution; use x, y or z for grain-boundary fraction along an axis."
        return (profile, note)
    }
}
