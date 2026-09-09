//
//  ColumnFieldTool.swift — colour atoms by any per-atom quantity.
//
//  The first generic tool (design §1 "Rendering & export"): a coordinate,
//  the charge, or any numeric column the dump/extended-XYZ carried (`q`,
//  `c_pe`, `vx`…). It exists to make the overlay + legend + chart + export
//  path real in phase 0c, and it is useful on its own (colour by potential
//  energy, by depth, by velocity).
//

import Foundation

public struct ColumnFieldTool: AnalysisTool {
    public static let id = "column_field"
    public static let title = "Colour by column"
    public static let category = ToolCategory.renderingExport
    public static let functions: Set<ToolFunction> = [.perAtomField, .profile, .scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = []
    public static let supportsStridedPreview = true

    public struct Parameters: Codable, Equatable {
        /// "x" | "y" | "z" | "charge" | any `Frame.columns` key.
        public var column: String
        public var colormap: String
        /// Fixed colour range; nil = this frame's min/max (auto).
        public var rangeMin: Float?
        public var rangeMax: Float?
        /// Profile: mean of the column in bins along `profileAxis`.
        public var profileAxis: Axis
        public var bins: Int

        public init(column: String = "z", colormap: String = "viridis",
                    rangeMin: Float? = nil, rangeMax: Float? = nil,
                    profileAxis: Axis = .z, bins: Int = 24) {
            self.column = column
            self.colormap = colormap
            self.rangeMin = rangeMin
            self.rangeMax = rangeMax
            self.profileAxis = profileAxis
            self.bins = bins
        }
    }

    public static let defaultParameters = Parameters()

    /// One pass to read the column, one to bin it.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 0.02 * Double(atoms) }

    /// Columns this frame can be coloured by (coordinates first, then data).
    public static func availableColumns(_ frame: Frame) -> [String] {
        var names = ["x", "y", "z"]
        if frame.atoms.contains(where: { $0.charge != nil }) { names.append("charge") }
        names += frame.columns.keys.filter { frame.column($0) != nil }.sorted()
        return names
    }

    static func values(_ frame: Frame, column: String) -> [Float]? {
        switch column {
        case "x": return frame.atoms.map { Float($0.x) }
        case "y": return frame.atoms.map { Float($0.y) }
        case "z": return frame.atoms.map { Float($0.z) }
        case "charge":
            guard frame.atoms.contains(where: { $0.charge != nil }) else { return nil }
            return frame.atoms.map { Float($0.charge ?? 0) }
        default: return frame.column(column)
        }
    }

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let v = values(frame, column: params.column) else {
            throw AnalysisError.notApplicable(
                "No per-atom column “\(params.column)” in this frame (have: \(availableColumns(frame).joined(separator: ", "))).")
        }
        guard !v.isEmpty else { throw AnalysisError.notApplicable("Empty frame.") }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var sum = 0.0, sumSq = 0.0
        for (n, x) in v.enumerated() {
            if x < lo { lo = x }
            if x > hi { hi = x }
            sum += Double(x); sumSq += Double(x) * Double(x)
            if n & 0xFFFF == 0xFFFF, context.isCancelled() { throw AnalysisError.cancelled }
        }
        let mean = sum / Double(v.count)
        let std = (sumSq / Double(v.count) - mean * mean).squareRoot()
        let rangeLo = params.rangeMin ?? lo, rangeHi = params.rangeMax ?? hi

        func fmt(_ x: Double) -> String { String(format: "%.4g", x) }
        let summary = [
            SummaryRow("Column", params.column),
            SummaryRow("Min", fmt(Double(lo))),
            SummaryRow("Mean", fmt(mean)),
            SummaryRow("Max", fmt(Double(hi))),
            SummaryRow("Std. dev.", fmt(std)),
            SummaryRow("Colour range", "\(fmt(Double(rangeLo))) … \(fmt(Double(rangeHi)))")
        ]
        let field = PerAtomField(name: params.column, values: v,
                                 palette: .continuous(min: rangeLo, max: rangeHi, colormapName: params.colormap),
                                 legendTitle: params.column)
        let profile = Binning.profile(frame: frame, axis: params.profileAxis, field: v,
                                      bins: params.bins, valueLabel: "mean \(params.column)")
        var notes: [String] = []
        if context.stride > 1 { notes.append("Preview: 1/\(context.stride) of atoms.") }
        return ToolResult(summary: summary, field: field, profile: profile, scalar: mean, notes: notes)
    }
}
