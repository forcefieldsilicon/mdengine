//
//  ZProfileTool.swift — the z-profile as the first registered tool.
//
//  Wraps `ZProfileAnalysis` UNCHANGED (same surface plane, same classification,
//  same histogram) and adds the "profile of anything" parameter the design asks
//  for: composition (today's counts), charge, or any per-atom column another
//  tool published into the frame. Default parameters reproduce today's numbers.
//

import Foundation

public struct ZProfileTool: AnalysisTool {
    public static let id = "z_profile"
    public static let title = "Z-profile"
    public static let category = ToolCategory.surfacesDeposition
    public static let functions: Set<ToolFunction> = [.profile, .scalar, .timeSeries]
    /// No box needed: depths are relative to the substrate's own surface plane.
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    /// What the bins hold. `.composition` = probe-atom counts, i.e. exactly
    /// today's `ZProfileAnalysis.histogram`.
    public enum ProfileOf: Codable, Equatable {
        case composition
        case charge
        case field(String)

        private enum CodingKeys: String, CodingKey { case kind, name }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .composition: try c.encode("composition", forKey: .kind)
            case .charge: try c.encode("charge", forKey: .kind)
            case .field(let n): try c.encode("field", forKey: .kind); try c.encode(n, forKey: .name)
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "charge": self = .charge
            case "field": self = .field(try c.decode(String.self, forKey: .name))
            default: self = .composition
            }
        }
    }

    public struct Parameters: Codable, Equatable {
        /// nil = pick the two most abundant elements, as the inspector does today.
        public var substrate: String?
        public var probe: String?
        public var bins: Int
        public var profileOf: ProfileOf

        public init(substrate: String? = nil, probe: String? = nil,
                    bins: Int = 12, profileOf: ProfileOf = .composition) {
            self.substrate = substrate
            self.probe = probe
            self.bins = bins
            self.profileOf = profileOf
        }
    }

    public static let defaultParameters = Parameters()

    /// Two filters + a sort over the frame.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double {
        0.05 * Double(atoms)
    }

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        let atoms = frame.atoms
        guard let picked = elements(atoms, params) else {
            throw AnalysisError.notApplicable("Need two distinct elements (substrate and probe).")
        }
        guard let zp = ZProfileAnalysis(frame: atoms, substrate: picked.substrate,
                                        probe: picked.probe, bins: params.bins) else {
            throw AnalysisError.notApplicable("Frame has no \(picked.substrate)/\(picked.probe) pair.")
        }
        guard !context.isCancelled() else { throw AnalysisError.cancelled }

        func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "—" }
        var summary = [
            SummaryRow("Substrate / probe", "\(zp.substrateElement) / \(zp.probeElement)"),
            SummaryRow("Surface plane z", fmt(zp.surfaceZ), unit: "Å"),
            SummaryRow("Substrate max z", fmt(zp.substrateMaxZ), unit: "Å"),
            SummaryRow("Penetrated", "\(zp.penetrations.count)"),
            SummaryRow("Max penetration", fmt(zp.maxPenetration), unit: "Å"),
            SummaryRow("Mean penetration", fmt(zp.meanPenetration), unit: "Å"),
            SummaryRow("At surface (≤ \(ZProfileAnalysis.surfaceBand) Å)", "\(zp.atSurfaceCount)"),
            SummaryRow("Above surface", "\(zp.aboveCount)")
        ]
        if let q = zp.boundProbeMeanCharge {
            summary.append(SummaryRow("Bound probe mean charge", fmt(q), unit: "e"))
        }

        // Probe atoms binned by depth relative to the surface plane — same
        // values ZProfileAnalysis histograms, so bins line up exactly.
        var notes: [String] = []
        let probes = atoms.indices.filter { atoms[$0].element == zp.probeElement }
        let rel = probes.map { atoms[$0].z - zp.surfaceZ }
        var values: [Double]?
        var valueLabel = "probe atoms"

        switch params.profileOf {
        case .composition:
            values = nil
        case .charge:
            values = probes.map { atoms[$0].charge ?? 0 }
            valueLabel = "mean charge (e)"
        case .field(let name):
            if let column = frame.column(name) {
                values = probes.map { Double(column[$0]) }
                valueLabel = "mean \(name)"
            } else {
                notes.append("No per-atom field “\(name)” in this frame — showing atom counts.")
            }
        }

        let profile = Binning.profile(coordinates: rel, values: values, bins: params.bins,
                                      axisLabel: "z − surface (Å)", valueLabel: valueLabel)
        if context.stride > 1 { notes.append("Preview: 1/\(context.stride) of atoms.") }

        return ToolResult(summary: summary, field: nil, profile: profile,
                          scalar: zp.maxPenetration ?? 0, notes: notes)
    }

    /// Explicit parameters win; otherwise the two most abundant elements.
    private static func elements(_ atoms: [Arv],
                                 _ params: Parameters) -> (substrate: String, probe: String)? {
        if let s = params.substrate, let p = params.probe, s != p { return (s, p) }
        guard let d = ZProfileAnalysis.defaultElements(for: atoms) else { return nil }
        return (params.substrate ?? d.substrate, params.probe ?? d.probe)
    }
}
