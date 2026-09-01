import Foundation

/// Depth analysis of a deposition/oxidation frame: locate the substrate's top
/// surface plane along z, then classify probe atoms (the deposited species)
/// by penetration depth relative to that plane.
///
/// Surface plane = mean z of the top 5% of substrate atoms — robust against
/// both single stray atoms (which a max would follow) and surface roughness.
public struct ZProfileAnalysis {
    public let substrateElement: String
    public let probeElement: String
    /// z of the substrate surface plane (Å).
    public let surfaceZ: Double
    /// z of the single highest substrate atom (Å).
    public let substrateMaxZ: Double
    /// Penetration depths (Å below the surface plane) of probe atoms under it, sorted ascending.
    public let penetrations: [Double]
    /// Probe atoms within `surfaceBand` Å above the plane (chemisorbed/at-surface).
    public let atSurfaceCount: Int
    /// Probe atoms above the surface band (in-flight / unreacted).
    public let aboveCount: Int
    /// Mean charge of probe atoms at or below the surface, when charges exist.
    public let boundProbeMeanCharge: Double?
    /// Histogram of probe z relative to the surface plane (negative = penetrated).
    public let histogram: [(range: ClosedRange<Double>, count: Int)]

    public static let surfaceBand = 2.5

    public var maxPenetration: Double? { penetrations.last }
    public var minPenetration: Double? { penetrations.first }
    public var meanPenetration: Double? {
        penetrations.isEmpty ? nil : penetrations.reduce(0, +) / Double(penetrations.count)
    }

    /// nil when the frame lacks either element.
    public init?(frame: [Arv], substrate: String, probe: String, bins: Int = 12) {
        let sub = frame.filter { $0.element == substrate }
        let prb = frame.filter { $0.element == probe }
        guard !sub.isEmpty, !prb.isEmpty, substrate != probe else { return nil }
        substrateElement = substrate
        probeElement = probe

        let subZ = sub.map(\.z).sorted()
        substrateMaxZ = subZ.last!
        let top = subZ.suffix(max(1, subZ.count / 20))
        let surf = top.reduce(0, +) / Double(top.count)
        surfaceZ = surf

        let rel = prb.map { $0.z - surf }
        penetrations = rel.filter { $0 < 0 }.map { -$0 }.sorted()
        atSurfaceCount = rel.filter { (0..<Self.surfaceBand).contains($0) }.count
        aboveCount = rel.filter { $0 >= Self.surfaceBand }.count

        let bound = zip(prb, rel).filter { $0.1 < Self.surfaceBand }.compactMap { $0.0.charge }
        boundProbeMeanCharge = bound.isEmpty ? nil : bound.reduce(0, +) / Double(bound.count)

        let lo = rel.min()!, hi = rel.max()!
        let width = max(0.5, (hi - lo) / Double(bins))
        var hist: [(ClosedRange<Double>, Int)] = []
        var edge = lo
        while edge < hi || hist.isEmpty {
            let range = edge...(edge + width)
            let count = rel.filter { $0 >= edge && ($0 < edge + width || edge + width >= hi) }.count
            hist.append((range, count))
            edge += width
        }
        histogram = hist
    }

    /// Substrate/probe defaults for a frame: most abundant element is the
    /// substrate; the most abundant *other* element is the probe.
    public static func defaultElements(for frame: [Arv]) -> (substrate: String, probe: String)? {
        var counts: [String: Int] = [:]
        for a in frame { counts[a.element, default: 0] += 1 }
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        guard ranked.count >= 2 else { return nil }
        return (ranked[0].key, ranked[1].key)
    }
}
