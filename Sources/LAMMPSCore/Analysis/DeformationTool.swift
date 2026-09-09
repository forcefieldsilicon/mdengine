//
//  DeformationTool.swift — per-atom strain, D²min and displacement vs a
//  reference frame (design §2.2).
//
//  Falk & Langer 1998 (PRE 57 7192): fit the best affine map F of each atom's
//  reference neighbourhood onto its current one; what the fit cannot explain is
//  D²min, the non-affine (plastic) displacement. Strain invariants follow
//  Shimizu, Ogata & Li 2007 (Mater. Trans. 48 2923) — the Green–Lagrangian
//  formulation OVITO's Atomic Strain uses, so numbers are comparable.
//
//  Neighbours are taken in the REFERENCE frame: the question is "what happened
//  to the atoms that used to surround me", not "who is near me now".
//

import Foundation

public struct DeformationTool: AnalysisTool {
    public static let id = "deformation"
    public static let title = "Deformation"
    public static let category = ToolCategory.mechanicsDeformation
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.referenceFrame]
    /// A strided subset would change every atom's neighbourhood, so the strain
    /// would be a different quantity, not a coarser view of the same one.
    public static let supportsStridedPreview = false

    /// Which per-atom quantity becomes the field / the profile / the scalar.
    public enum Quantity: String, CaseIterable {
        case shear, volumetric, d2min, displacement, rearranged
        case vonmisesStress = "vonmises_stress"

        var fieldName: String {
            switch self {
            case .shear: return "shear strain"
            case .volumetric: return "volumetric strain"
            case .d2min: return "D²min"
            case .displacement: return "displacement"
            case .rearranged: return "rearranged"
            case .vonmisesStress: return "von Mises stress"
            }
        }
        /// Fields that are magnitudes start their colour ramp at zero.
        var zeroBased: Bool { self == .d2min || self == .displacement }
    }

    public struct Parameters: Codable, Equatable {
        /// Neighbour cutoff, applied in the reference frame (Å).
        public var cutoff: Double
        /// One of `Quantity`'s raw values.
        public var quantity: String
        /// D²min above this counts as "rearranged" (Å²).
        public var d2minThreshold: Double
        /// Read per-atom stress columns when the frame carries them.
        public var stressColumns: Bool
        public var profileAxis: Axis
        public var bins: Int

        public init(cutoff: Double = 3.5, quantity: String = "shear",
                    d2minThreshold: Double = 0.5, stressColumns: Bool = true,
                    profileAxis: Axis = .z, bins: Int = 24) {
            self.cutoff = cutoff
            self.quantity = quantity
            self.d2minThreshold = d2minThreshold
            self.stressColumns = stressColumns
            self.profileAxis = profileAxis
            self.bins = bins
        }
    }

    public static let defaultParameters = Parameters()

    /// One neighbour-list build plus a ~12-neighbour 3×3 fit per atom.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 1.5 * Double(atoms) }

    // MARK: - Per-atom results

    struct PerAtom {
        var shear = Double.nan
        var volumetric = Double.nan
        var volumeChange = Double.nan          // J = det F − 1
        var d2min = Double.nan
        var displacement = Double.nan
        var valid = false
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let reference = context.referenceFrame else {
            throw AnalysisError.missingRequirement(.referenceFrame)
        }
        let n = frame.count
        guard n > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        guard reference.count == n else {
            throw AnalysisError.notApplicable(
                "Reference frame has \(reference.count) atoms and this frame has \(n) — atoms cannot be matched.")
        }
        guard let quantity = Quantity(rawValue: params.quantity) else {
            throw AnalysisError.notApplicable(
                "Unknown quantity “\(params.quantity)” (have: \(Quantity.allCases.map(\.rawValue).joined(separator: ", "))).")
        }
        let stress = params.stressColumns ? vonMisesStress(frame) : nil
        if quantity == .vonmisesStress, stress == nil {
            throw AnalysisError.notApplicable(
                "This frame carries no per-atom stress columns (c_stress[1..6] or sxx…syz).")
        }
        var notes: [String] = []
        let refPositions = alignedReferencePositions(frame: frame, reference: reference, notes: &notes)
        let positions = frame.positions
        let refBox = reference.box, box = frame.box
        if refBox == nil || box == nil {
            notes.append("No box on \(refBox == nil ? "the reference" : "this") frame — distances are unwrapped.")
        }
        if refBox?.isTriclinic == true || box?.isTriclinic == true {
            notes.append("Triclinic cell: minimum image is applied as if orthogonal.")
        }

        // The context's neighbour cache is keyed by the CURRENT frame index, so
        // it cannot hold a reference-frame list; build our own once per call.
        // (A cache keyed by `context.referenceFrameIndex` could share this
        // across tools/frames later — the reference rarely changes.)
        let neighbors = NeighborList(positions: refPositions, cutoff: params.cutoff,
                                     box: refBox, isCancelled: context.isCancelled)
        if neighbors.wasCancelled { throw AnalysisError.cancelled }

        var per = [PerAtom](repeating: PerAtom(), count: n)
        var msdSum = 0.0
        for i in 0..<n {
            if i % 2048 == 0, context.isCancelled() { throw AnalysisError.cancelled }

            var d = positions[i] - refPositions[i]
            if let box { d = box.minimumImage(d) }
            let displacement = (d * d).sum().squareRoot()
            per[i].displacement = displacement
            msdSum += displacement * displacement

            var v = Mat3.zero, w = Mat3.zero
            var neighborCount = 0
            var refVectors: [SIMD3<Double>] = []
            var curVectors: [SIMD3<Double>] = []
            refVectors.reserveCapacity(16); curVectors.reserveCapacity(16)
            neighbors.forEachNeighbor(of: i) { j, _ in
                var d0 = refPositions[j] - refPositions[i]
                if let refBox { d0 = refBox.minimumImage(d0) }
                var dt = positions[j] - positions[i]
                if let box { dt = box.minimumImage(dt) }
                v += Mat3.outer(d0, d0)
                w += Mat3.outer(d0, dt)
                refVectors.append(d0); curVectors.append(dt)
                neighborCount += 1
            }
            guard neighborCount >= 3, let vInv = v.inverse else { continue }   // stays NaN, counted below

            // V⁻¹W maps reference onto current as ROW vectors; the deformation
            // gradient with d ≈ F·d0 (needed by D²min, and the only form for
            // which a rigid rotation gives zero strain) is its transpose.
            let f = (vInv * w).transposed
            guard f.r0.x.isFinite, f.r1.y.isFinite, f.r2.z.isFinite else { continue }

            var residual = 0.0
            for (k, d0) in refVectors.enumerated() {
                let diff = curVectors[k] - (f * d0)
                residual += (diff * diff).sum()
            }
            let e = f.greenLagrangianStrain
            per[i].shear = e.vonMisesShear
            per[i].volumetric = e.trace / 3
            per[i].volumeChange = f.determinant - 1
            per[i].d2min = residual / Double(neighborCount)
            per[i].valid = true
        }

        // MARK: Aggregates
        let validCount = per.reduce(0) { $0 + ($1.valid ? 1 : 0) }
        let shear = per.map(\.shear), volumetric = per.map(\.volumetric)
        let d2min = per.map(\.d2min), displacement = per.map(\.displacement)
        let rearranged = d2min.map { $0.isFinite && $0 > params.d2minThreshold }
        let rearrangedCount = rearranged.reduce(0) { $0 + ($1 ? 1 : 0) }
        let msd = msdSum / Double(n)

        func fmt(_ x: Double) -> String { x.isFinite ? String(format: "%.4g", x) : "—" }
        var summary = [
            SummaryRow("Atoms", "\(n)"),
            SummaryRow("Valid fits", "\(validCount)" + (validCount < n ? " of \(n)" : "")),
            SummaryRow("Mean shear strain", fmt(mean(shear))),
            SummaryRow("95th pct shear strain", fmt(percentile(shear, 0.95))),
            SummaryRow("Mean volumetric strain", fmt(mean(volumetric))),
            SummaryRow("Mean volume change", fmt(mean(per.map(\.volumeChange)))),
            SummaryRow("Mean D²min", fmt(mean(d2min)), unit: "Å²"),
            SummaryRow("Fraction rearranged", fmt(Double(rearrangedCount) / Double(n)),
                       unit: "D²min > \(fmt(params.d2minThreshold)) Å²"),
            SummaryRow("Mean displacement", fmt(mean(displacement)), unit: "Å"),
            SummaryRow("MSD", fmt(msd), unit: "Å²")
        ]
        if let box, let refBox {
            let l = box.lengths, l0 = refBox.lengths
            let strain = (0..<3).map { l0[$0] > 0 ? (l[$0] - l0[$0]) / l0[$0] : Double.nan }
            summary.append(SummaryRow("Box strain", strain.map(fmt).joined(separator: ", "), unit: "x, y, z"))
        }
        if let stress {
            summary.append(SummaryRow("Mean von Mises stress", fmt(mean(stress.map(Double.init))),
                                      unit: "stress units"))
        }

        // MARK: Field, profile, scalar
        let values: [Double]
        switch quantity {
        case .shear: values = shear
        case .volumetric: values = volumetric
        case .d2min: values = d2min
        case .displacement: values = displacement
        case .rearranged: values = rearranged.map { $0 ? 1 : 0 }
        case .vonmisesStress: values = (stress ?? []).map(Double.init)
        }
        let floats = values.map(Float.init)
        let palette: FieldPalette
        if quantity == .rearranged {
            palette = .categorical([("affine", RGB(0.6, 0.6, 0.6)), ("rearranged", RGB(1.0, 0.55, 0.1))])
        } else {
            let lo = quantity.zeroBased ? 0 : (values.filter(\.isFinite).min() ?? 0)
            // A perfectly uniform field (rigid motion) would give lo == hi and a
            // degenerate ramp; widen by an epsilon rather than divide by zero.
            let hi = max(percentile(values, 0.95), lo + 1e-9)
            palette = .continuous(min: Float(lo), max: Float(hi), colormapName: "inferno")
        }
        let field = PerAtomField(name: quantity.fieldName, values: floats,
                                 palette: palette, legendTitle: quantity.fieldName)
        let profile = Binning.profile(frame: frame, axis: params.profileAxis, field: floats,
                                      bins: params.bins, valueLabel: "mean \(quantity.fieldName)")
        if validCount < n { notes.append("\(n - validCount) atoms had too few (or coplanar) reference neighbours — no fit.") }
        return ToolResult(summary: summary, field: field, profile: profile,
                          scalar: mean(values), notes: notes)
    }

    // MARK: - Helpers

    /// Reference positions reordered into THIS frame's atom order: by `id` when
    /// both frames carry one on every atom (ids are the only honest identity
    /// across a dump that reordered atoms), else by index.
    static func alignedReferencePositions(frame: Frame, reference: Frame,
                                          notes: inout [String]) -> [SIMD3<Double>] {
        let refPositions = reference.positions
        let ids = frame.atoms.compactMap(\.id), refIds = reference.atoms.compactMap(\.id)
        guard ids.count == frame.count, refIds.count == reference.count else { return refPositions }
        var slot = [Int: Int](minimumCapacity: refIds.count)
        for (i, id) in refIds.enumerated() { slot[id] = i }
        guard slot.count == refIds.count else {              // duplicate ids: not an identity
            notes.append("Duplicate atom ids in the reference frame — matched by index instead.")
            return refPositions
        }
        var out = [SIMD3<Double>](repeating: .zero, count: frame.count)
        for (i, id) in ids.enumerated() {
            guard let j = slot[id] else {
                notes.append("Atom ids do not match between the frames — matched by index instead.")
                return refPositions
            }
            out[i] = refPositions[j]
        }
        return out
    }

    /// Per-atom von Mises stress from six virial columns, when they are there.
    /// Accepts `c_stress[1..6]` / `v_…[1..6]` (LAMMPS order xx yy zz xy xz yz)
    /// and named `sxx syy szz sxy sxz syz`, with any `c_`/`v_` prefix stripped.
    static func vonMisesStress(_ frame: Frame) -> [Float]? {
        guard let components = stressComponents(frame) else { return nil }
        return (0..<frame.count).map { i in
            let t = Mat3(SIMD3(Double(components[0][i]), Double(components[3][i]), Double(components[4][i])),
                         SIMD3(Double(components[3][i]), Double(components[1][i]), Double(components[5][i])),
                         SIMD3(Double(components[4][i]), Double(components[5][i]), Double(components[2][i])))
            return Float(t.vonMisesShear * 3.0.squareRoot())   // √3 × the deviatoric invariant
        }
    }

    /// The six columns in xx, yy, zz, xy, xz, yz order, or nil.
    static func stressComponents(_ frame: Frame) -> [[Float]]? {
        let names = ["sxx", "syy", "szz", "sxy", "sxz", "syz"]
        var bracketed: [String: [Int: [Float]]] = [:]
        var named: [Int: [Float]] = [:]
        for key in frame.columns.keys.sorted() {
            guard let column = frame.column(key) else { continue }
            var base = key
            for prefix in ["c_", "v_"] where base.hasPrefix(prefix) { base.removeFirst(prefix.count) }
            if let open = base.lastIndex(of: "["), base.hasSuffix("]") {
                let inner = base[base.index(after: open)..<base.index(before: base.endIndex)]
                if let k = Int(inner), (1...6).contains(k) {
                    bracketed[String(base[base.startIndex..<open]), default: [:]][k - 1] = column
                }
            } else if let k = names.firstIndex(of: base.lowercased()) {
                named[k] = column
            }
        }
        for base in bracketed.keys.sorted() {
            if let group = bracketed[base], group.count == 6 { return (0..<6).map { group[$0]! } }
        }
        guard named.count == 6 else { return nil }
        return (0..<6).map { named[$0]! }
    }

    /// Mean over the finite entries (atoms without a fit are NaN, not zero —
    /// averaging them in would quietly bias every summary toward zero).
    static func mean(_ values: [Double]) -> Double {
        var sum = 0.0, count = 0
        for v in values where v.isFinite { sum += v; count += 1 }
        return count == 0 ? .nan : sum / Double(count)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return .nan }
        let idx = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
