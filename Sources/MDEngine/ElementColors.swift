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
        default:
            // Native dumps without an element column carry numeric type tokens;
            // give each unknown token a stable, distinct colour.
            var h: UInt32 = 2_166_136_261
            for b in element.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
            let hue = Float(h % 360) / 360
            return hsv(hue, 0.55, 0.88)
        }
    }

    private static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = Int(h * 6) % 6
        let f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }

    static func color(for element: String) -> Color {
        let c = rgb(for: element)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
