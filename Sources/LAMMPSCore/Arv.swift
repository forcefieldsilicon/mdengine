import Foundation

public struct Arv {
    public let element: String
    public let x: Double
    public let y: Double
    public let z: Double
    /// Per-atom charge (native dumps with a q column); nil when absent.
    public let charge: Double?

    public init(element: String, x: Double, y: Double, z: Double, charge: Double? = nil) {
        self.element = element
        self.x = x
        self.y = y
        self.z = z
        self.charge = charge
    }
}

public extension Array where Element == [Arv] {
    /// Map numeric type tokens to element symbols by position (1-based):
    /// symbols ["O", "Al"] renames type "1" → O, "2" → Al. Non-numeric or
    /// out-of-range tokens pass through unchanged.
    func mappingElements(_ symbols: [String]) -> [[Arv]] {
        guard !symbols.isEmpty else { return self }
        return map { frame in
            frame.map { a in
                guard let t = Int(a.element), t >= 1, t <= symbols.count else { return a }
                return Arv(element: symbols[t - 1], x: a.x, y: a.y, z: a.z, charge: a.charge)
            }
        }
    }
}
