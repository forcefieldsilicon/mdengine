import SwiftUI

/// CPK-style element colours shared by the Metal renderer and the SwiftUI chrome.
enum ElementColors {
    static func rgb(for element: String) -> SIMD3<Float> {
        switch element {
        case "H":  return SIMD3<Float>(0.95, 0.95, 0.95)
        case "C":  return SIMD3<Float>(0.56, 0.56, 0.56)
        case "N":  return SIMD3<Float>(0.30, 0.42, 0.93)
        case "O":  return SIMD3<Float>(1.00, 0.20, 0.18)
        case "Al": return SIMD3<Float>(0.75, 0.76, 0.80)
        case "Si": return SIMD3<Float>(0.94, 0.78, 0.63)
        case "Ar": return SIMD3<Float>(0.50, 0.82, 0.89)
        case "Fe": return SIMD3<Float>(0.88, 0.40, 0.20)
        case "Cu": return SIMD3<Float>(0.78, 0.50, 0.20)
        default:   return SIMD3<Float>(0.90, 0.90, 0.90)
        }
    }

    static func color(for element: String) -> Color {
        let c = rgb(for: element)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
