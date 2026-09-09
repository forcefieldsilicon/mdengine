//
//  ToolResult.swift — what every analysis tool returns.
//
//  One shape for all tools so the inspector, the overlay, CSV export and the
//  MCP `analyze` verb each need exactly one renderer, and a phase-2 external
//  (Python) tool can produce the same JSON.
//

import Foundation

/// One line of the tool's results table.
public struct SummaryRow: Codable, Equatable {
    public let label: String
    public let value: String
    public let unit: String?
    public init(_ label: String, _ value: String, unit: String? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
    }
}

public struct RGB: Codable, Equatable {
    public let r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
}

/// How a per-atom field maps to colour on the rendered view.
public enum FieldPalette: Codable, Equatable {
    /// Discrete classes; a field value of `n` picks entry `n`.
    case categorical([(label: String, color: RGB)])
    /// Continuous ramp between `min` and `max` using a named colormap.
    case continuous(min: Float, max: Float, colormapName: String)

    private struct Category: Codable, Equatable { let label: String; let color: RGB }
    private enum CodingKeys: String, CodingKey { case kind, categories, min, max, colormapName }

    public static func == (a: FieldPalette, b: FieldPalette) -> Bool {
        switch (a, b) {
        case let (.categorical(x), .categorical(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.label == $1.label && $0.color == $1.color }
        case let (.continuous(l1, h1, n1), .continuous(l2, h2, n2)):
            return l1 == l2 && h1 == h2 && n1 == n2
        default: return false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .categorical(entries):
            try c.encode("categorical", forKey: .kind)
            try c.encode(entries.map { Category(label: $0.label, color: $0.color) }, forKey: .categories)
        case let .continuous(min, max, name):
            try c.encode("continuous", forKey: .kind)
            try c.encode(min, forKey: .min)
            try c.encode(max, forKey: .max)
            try c.encode(name, forKey: .colormapName)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "categorical" {
            let entries = try c.decode([Category].self, forKey: .categories)
            self = .categorical(entries.map { ($0.label, $0.color) })
        } else {
            self = .continuous(min: try c.decode(Float.self, forKey: .min),
                               max: try c.decode(Float.self, forKey: .max),
                               colormapName: try c.decode(String.self, forKey: .colormapName))
        }
    }
}

/// A value per atom, parallel to the frame's atoms. Float32 by policy.
public struct PerAtomField: Codable, Equatable {
    public let name: String
    public let values: [Float]
    public let palette: FieldPalette
    public let legendTitle: String
    public init(name: String, values: [Float], palette: FieldPalette, legendTitle: String) {
        self.name = name
        self.values = values
        self.palette = palette
        self.legendTitle = legendTitle
    }
}

/// A binned profile along an axis: `edges` has `values.count + 1` entries.
public struct Profile: Codable, Equatable {
    public let axisLabel: String
    public let valueLabel: String
    public let edges: [Double]
    public let values: [Double]
    public let counts: [Int]
    public init(axisLabel: String, valueLabel: String, edges: [Double], values: [Double], counts: [Int]) {
        self.axisLabel = axisLabel
        self.valueLabel = valueLabel
        self.edges = edges
        self.values = values
        self.counts = counts
    }
    /// Bin midpoints, for plotting.
    public var centers: [Double] {
        guard edges.count > 1 else { return [] }
        return (0..<(edges.count - 1)).map { (edges[$0] + edges[$0 + 1]) / 2 }
    }
}

public struct ToolResult: Codable, Equatable {
    public var summary: [SummaryRow]
    public var field: PerAtomField?
    public var profile: Profile?
    /// The one number worth plotting over frames (time series).
    public var scalar: Double?
    /// Caveats for the user ("no box — distances unwrapped", "preview, 1/4 of atoms").
    public var notes: [String]
    /// The scalar over EVERY frame, when the tool already knows it from a side file
    /// (pull-off energetics: the whole force curve). The inspector charts it at once
    /// instead of re-running the tool per frame; nil = compute on demand. Not encoded
    /// (the CSV is the source of record; MCP/CLI results stay as they were).
    public var series: [Int: Double]?
    public var seriesLabel: String?

    public init(summary: [SummaryRow] = [], field: PerAtomField? = nil,
                profile: Profile? = nil, scalar: Double? = nil, notes: [String] = [],
                series: [Int: Double]? = nil, seriesLabel: String? = nil) {
        self.summary = summary
        self.field = field
        self.profile = profile
        self.scalar = scalar
        self.notes = notes
        self.series = series
        self.seriesLabel = seriesLabel
    }

    private enum CodingKeys: String, CodingKey { case summary, field, profile, scalar, notes }

    /// Rough retained size, used by `FieldCache` to bound memory by bytes.
    public var estimatedBytes: Int {
        var n = 128
        n += summary.count * 96
        n += notes.reduce(0) { $0 + $1.utf8.count + 16 }
        if let f = field { n += f.values.count * MemoryLayout<Float>.size + 128 }
        if let p = profile { n += (p.edges.count + p.values.count) * 8 + p.counts.count * 8 + 128 }
        if let s = series { n += s.count * 24 }
        return n
    }
}
