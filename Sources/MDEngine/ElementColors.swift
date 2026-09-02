import SwiftUI
import MDRender

/// SwiftUI face of the shared CPK palette (AtomPalette in MDRender).
enum ElementColors {
    static func rgb(for element: String) -> SIMD3<Float> { ElementStyleStore.color(for: element) }

    static func color(for element: String) -> Color {
        let c = rgb(for: element)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

/// Persisted per-element style overrides (UserDefaults-backed):
/// `elemColor.<token>` = "r g b" (0…1 floats), `elemSize.<token>` = factor.
enum ElementStyleStore {
    static func currentStyle() -> AtomStyle {
        var colors: [String: SIMD3<Float>] = [:]
        var sizes: [String: Float] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            if key.hasPrefix("elemColor."), let s = value as? String {
                let p = s.split(separator: " ").compactMap { Float($0) }
                if p.count == 3 { colors[String(key.dropFirst(10))] = SIMD3(p[0], p[1], p[2]) }
            } else if key.hasPrefix("elemSize."), let d = value as? Double {
                sizes[String(key.dropFirst(9))] = Float(d)
            }
        }
        return AtomStyle(colors: colors, sizes: sizes)
    }

    static func setColor(_ rgb: SIMD3<Float>, for element: String) {
        UserDefaults.standard.set("\(rgb.x) \(rgb.y) \(rgb.z)", forKey: "elemColor.\(element)")
    }

    static func setSize(_ factor: Double, for element: String) {
        UserDefaults.standard.set(factor, forKey: "elemSize.\(element)")
    }

    static func reset(elements: [String]) {
        for e in elements {
            UserDefaults.standard.removeObject(forKey: "elemColor.\(e)")
            UserDefaults.standard.removeObject(forKey: "elemSize.\(e)")
        }
    }

    /// Restore Defaults resets sizes but keeps the user's colors.
    static func resetSizes(elements: [String]) {
        for e in elements {
            UserDefaults.standard.removeObject(forKey: "elemSize.\(e)")
        }
    }

    static func color(for element: String) -> SIMD3<Float> {
        currentStyle().color(for: element)
    }
}
