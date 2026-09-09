//
//  FieldColors.swift — per-atom field → colour, shared by the live view, the
//  offscreen exporter and the legend (design §1, "one new colour source").
//
//  Colormaps are short control-point tables, linearly interpolated: enough
//  for a legend and an overlay, no dependency. Names are the matplotlib ones
//  people already know.
//

import Foundation
import simd
import LAMMPSCore

public enum FieldColors {
    /// Control points (sRGB 0…1) sampled from the matplotlib maps.
    private static let maps: [String: [SIMD3<Float>]] = [
        "viridis": [[0.267, 0.005, 0.329], [0.283, 0.141, 0.458], [0.254, 0.265, 0.530],
                    [0.207, 0.372, 0.553], [0.164, 0.471, 0.558], [0.128, 0.567, 0.551],
                    [0.135, 0.659, 0.518], [0.267, 0.749, 0.441], [0.478, 0.821, 0.318],
                    [0.741, 0.873, 0.150], [0.993, 0.906, 0.144]],
        "inferno": [[0.001, 0.000, 0.014], [0.088, 0.041, 0.242], [0.257, 0.038, 0.407],
                    [0.416, 0.090, 0.433], [0.578, 0.148, 0.404], [0.735, 0.215, 0.330],
                    [0.866, 0.317, 0.226], [0.955, 0.463, 0.100], [0.988, 0.645, 0.040],
                    [0.965, 0.836, 0.256], [0.988, 0.998, 0.645]],
        "coolwarm": [[0.230, 0.299, 0.754], [0.406, 0.538, 0.934], [0.602, 0.731, 0.999],
                     [0.788, 0.846, 0.939], [0.867, 0.867, 0.867], [0.941, 0.802, 0.732],
                     [0.958, 0.648, 0.529], [0.887, 0.446, 0.361], [0.706, 0.016, 0.150]],
        "grey": [[0.10, 0.10, 0.10], [0.95, 0.95, 0.95]],
    ]

    public static var colormapNames: [String] { ["viridis", "inferno", "coolwarm", "grey"] }

    /// Colour at `t` in 0…1 on the named map (unknown names fall back to viridis).
    public static func sample(_ name: String, at t: Float) -> SIMD3<Float> {
        let table = maps[name] ?? maps["viridis"]!
        let x = max(0, min(1, t)) * Float(table.count - 1)
        let i = Int(x.rounded(.down))
        if i >= table.count - 1 { return table[table.count - 1] }
        let f = x - Float(i)
        return table[i] * (1 - f) + table[i + 1] * f
    }

    public static func color(value: Float, palette: FieldPalette) -> SIMD3<Float> {
        switch palette {
        case .categorical(let entries):
            guard !entries.isEmpty else { return SIMD3(0.6, 0.6, 0.6) }
            let i = max(0, min(entries.count - 1, Int(value.rounded())))
            let c = entries[i].color
            return SIMD3(c.r, c.g, c.b)
        case .continuous(let lo, let hi, let name):
            let span = hi - lo
            let t: Float = span > 0 ? (value - lo) / span : 0.5
            return value.isFinite ? sample(name, at: t) : SIMD3(0.5, 0.5, 0.5)
        }
    }

    /// One colour per atom, parallel to the field's values.
    public static func colors(for field: PerAtomField) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: SIMD3(0.6, 0.6, 0.6), count: field.values.count)
        switch field.palette {
        case .categorical(let entries):
            let table = entries.map { SIMD3($0.color.r, $0.color.g, $0.color.b) }
            guard !table.isEmpty else { return out }
            for (n, v) in field.values.enumerated() {
                out[n] = table[max(0, min(table.count - 1, Int(v.rounded())))]
            }
        case .continuous(let lo, let hi, let name):
            let span = hi - lo
            for (n, v) in field.values.enumerated() {
                let t: Float = span > 0 ? (v - lo) / span : 0.5
                out[n] = v.isFinite ? sample(name, at: t) : SIMD3(0.5, 0.5, 0.5)
            }
        }
        return out
    }

    /// What a legend must draw, in either medium (SwiftUI live view, CoreText export).
    public enum Legend: Equatable {
        case swatches(title: String, entries: [(label: String, color: SIMD3<Float>)])
        case colorBar(title: String, min: Float, max: Float, colormapName: String)

        public static func == (a: Legend, b: Legend) -> Bool {
            switch (a, b) {
            case let (.swatches(t1, e1), .swatches(t2, e2)):
                return t1 == t2 && e1.count == e2.count
                    && zip(e1, e2).allSatisfy { $0.label == $1.label && $0.color == $1.color }
            case let (.colorBar(t1, l1, h1, n1), .colorBar(t2, l2, h2, n2)):
                return t1 == t2 && l1 == l2 && h1 == h2 && n1 == n2
            default: return false
            }
        }
    }

    public static func legend(for field: PerAtomField) -> Legend {
        switch field.palette {
        case .categorical(let entries):
            return .swatches(title: field.legendTitle,
                             entries: entries.map { ($0.label, SIMD3($0.color.r, $0.color.g, $0.color.b)) })
        case .continuous(let lo, let hi, let name):
            return .colorBar(title: field.legendTitle, min: lo, max: hi, colormapName: name)
        }
    }
}
