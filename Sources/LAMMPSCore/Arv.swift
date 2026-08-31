import Foundation

public struct Arv: Identifiable {
    public let id = UUID()
    public let element: String
    public let x: Double
    public let y: Double
    public let z: Double

    public init(element: String, x: Double, y: Double, z: Double) {
        self.element = element
        self.x = x
        self.y = y
        self.z = z
    }
}
