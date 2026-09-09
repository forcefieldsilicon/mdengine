//
//  Binning.swift — "profile of anything along an axis".
//
//  The z-profile's histogram generalized: any per-atom quantity (counts, a
//  charge, a crystallinity fraction published by another tool) binned along
//  x/y/z. The bin geometry is deliberately IDENTICAL to
//  `ZProfileAnalysis.histogram` so the migrated tool reproduces today's numbers
//  bin for bin (`AnalysisFoundationTests` asserts it).
//

import Foundation

public enum Axis: String, Codable, CaseIterable {
    case x, y, z
    public var index: Int { self == .x ? 0 : (self == .y ? 1 : 2) }
    public var label: String { rawValue }
}

public enum Binning {
    /// Bin ranges over `[lo, hi]`, matching ZProfileAnalysis: width is
    /// `max(minWidth, (hi-lo)/bins)`, edges accumulate by repeated addition
    /// (so rounding matches), and the walk stops once `edge >= hi`.
    public static func ranges(lo: Double, hi: Double, bins: Int = 12,
                              minWidth: Double = 0.5) -> [ClosedRange<Double>] {
        let width = max(minWidth, (hi - lo) / Double(max(1, bins)))
        var out: [ClosedRange<Double>] = []
        var edge = lo
        while edge < hi || out.isEmpty {
            out.append(edge...(edge + width))
            edge += width
        }
        return out
    }

    /// Counts per bin — bit-for-bit the same as `ZProfileAnalysis.histogram`
    /// for the same values and bin count.
    public static func histogram(_ values: [Double], bins: Int = 12,
                                 minWidth: Double = 0.5) -> [(range: ClosedRange<Double>, count: Int)] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        return ranges(lo: lo, hi: hi, bins: bins, minWidth: minWidth).map { range in
            // Last bin is inclusive at `hi` — otherwise the maximum atom falls out.
            let count = values.filter { $0 >= range.lowerBound
                                     && ($0 < range.upperBound || range.upperBound >= hi) }.count
            return (range, count)
        }
    }

    /// Profile of `values` (nil = atom counts) against `coordinates`.
    /// Bin value = mean of the atoms in the bin; empty bins report 0 with count 0.
    public static func profile(coordinates: [Double],
                               values: [Double]? = nil,
                               bins: Int = 12,
                               minWidth: Double = 0.5,
                               axisLabel: String,
                               valueLabel: String) -> Profile {
        guard let lo = coordinates.min(), let hi = coordinates.max() else {
            return Profile(axisLabel: axisLabel, valueLabel: valueLabel, edges: [], values: [], counts: [])
        }
        let ranges = ranges(lo: lo, hi: hi, bins: bins, minWidth: minWidth)
        var counts = [Int](repeating: 0, count: ranges.count)
        var sums = [Double](repeating: 0, count: ranges.count)
        for (i, c) in coordinates.enumerated() {
            guard let b = ranges.firstIndex(where: { c >= $0.lowerBound
                                                 && (c < $0.upperBound || $0.upperBound >= hi) }) else { continue }
            counts[b] += 1
            sums[b] += values?[i] ?? 1
        }
        let binValues = values == nil
            ? counts.map(Double.init)
            : (0..<ranges.count).map { counts[$0] == 0 ? 0 : sums[$0] / Double(counts[$0]) }
        var edges = ranges.map(\.lowerBound)
        edges.append(ranges.last!.upperBound)
        return Profile(axisLabel: axisLabel, valueLabel: valueLabel,
                       edges: edges, values: binValues, counts: counts)
    }

    /// Convenience: bin a per-atom Float field along a box axis.
    public static func profile(frame: Frame, axis: Axis, field: [Float]?, bins: Int = 12,
                               valueLabel: String) -> Profile {
        let coords = frame.atoms.map { axis == .x ? $0.x : (axis == .y ? $0.y : $0.z) }
        return profile(coordinates: coords, values: field?.map(Double.init), bins: bins,
                       axisLabel: axis.label, valueLabel: valueLabel)
    }
}
