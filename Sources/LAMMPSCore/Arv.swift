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
