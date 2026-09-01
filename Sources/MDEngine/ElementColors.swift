import SwiftUI
import MDRender

/// SwiftUI face of the shared CPK palette (AtomPalette in MDRender).
enum ElementColors {
    static func rgb(for element: String) -> SIMD3<Float> { AtomPalette.rgb(for: element) }

    static func color(for element: String) -> Color {
        let c = AtomPalette.rgb(for: element)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
