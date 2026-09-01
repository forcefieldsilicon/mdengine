import simd
import Foundation

/// Rendering primitives shared by the app's interactive Metal view and the
/// offscreen video renderer — one shader, one camera math, one palette, so
/// exported video is pixel-faithful to what the window shows.
public enum RenderCore {

    /// One vertex per atom; layout must match `Atom` in the shader.
    /// `size` is the element's relative factor (1 = the global Atom size).
    public struct RenderAtom {
        public var position: SIMD3<Float>
        public var color: SIMD3<Float>
        public var size: Float
        public init(position: SIMD3<Float>, color: SIMD3<Float>, size: Float = 1) {
            self.position = position
            self.color = color
            self.size = size
        }
    }

    /// Must match `Uniforms` in the shader. `maxPointSize` scales with output
    /// resolution so 4K exports don't cap sprites at interactive-window sizes.
    public struct Uniforms {
        public var mvp: simd_float4x4
        public var pointSize: Float
        public var maxPointSize: Float
        public init(mvp: simd_float4x4, pointSize: Float, maxPointSize: Float = 48) {
            self.mvp = mvp
            self.pointSize = pointSize
            self.maxPointSize = maxPointSize
        }
    }

    /// The renderer's vertical field of view (perspective), and the reference
    /// the orthographic projection and scale bars are matched to.
    public static let fovY = Float.pi / 4
    /// Point-size preferences are calibrated against a drawable this tall
    /// (a typical app window on retina); exports scale sprites by height/this.
    public static let referenceDrawableHeight: Float = 1200

    // MARK: - Camera math (column-major, right-handed, Metal [0,1] depth)

    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    public static func orthographic(height: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let w = height * aspect, h = height
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / w, 0, 0, 0),
            SIMD4<Float>(0, 2 / h, 0, 0),
            SIMD4<Float>(0, 0, -1 / (far - near), 0),
            SIMD4<Float>(0, 0, -near / (far - near), 1)
        ))
    }

    public static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    public static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    public static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    public static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    /// View matrix for the shared orbit camera rig. `roll` exists for canonical
    /// side views: a two-axis rig cannot show a z-up slab's Left face with z
    /// staying up; presets set it, interactive orbiting leaves it alone.
    public static func viewMatrix(yaw: Float, pitch: Float, distance: Float,
                                  pan: SIMD2<Float>, roll: Float = 0) -> simd_float4x4 {
        translation(pan.x, pan.y, -distance) * rotationZ(roll) * rotationX(pitch) * rotationY(yaw)
    }

    /// Projection for the shared camera. Orthographic frames the same height
    /// the perspective camera would see at `distance`, so the two match.
    public static func projection(orthographic: Bool, distance: Float, aspect: Float) -> simd_float4x4 {
        orthographic
            ? Self.orthographic(height: 2 * distance * tan(fovY / 2),
                                aspect: aspect, near: 0.05, far: 100)
            : perspective(fovY: fovY, aspect: aspect, near: 0.05, far: 100)
    }

    /// Round 1/2/5×10ⁿ Å length nearest the target — scale bars everywhere.
    public static func niceLength(targetAngstroms t: Double) -> Double {
        guard t > 0, t.isFinite else { return 10 }
        let base = pow(10.0, floor(log10(t)))
        let candidates = [base, 2 * base, 5 * base, 10 * base]
        return candidates.min { abs($0 - t) < abs($1 - t) } ?? 10
    }

    /// Canonical view presets for z-up MD data (slabs, deposition boxes).
    /// Isometric looks from the (−x, +y, +z) corner (direction cosines
    /// 135°/45°/−45° to the axes) — the app's home view. Left needs camera
    /// roll to keep z up.
    public enum ViewPreset: String, CaseIterable {
        case isometric, top, bottom, front, rear, left
        public var viewAngles: (yaw: Float, pitch: Float, roll: Float) {
            switch self {
            case .isometric: return (.pi / 4, atan(1 / sqrt(2)), 0)
            case .top:    return (0, 0, 0)
            case .bottom: return (0, .pi, 0)
            case .front:  return (0, -.pi / 2, 0)
            case .rear:   return (.pi, .pi / 2, 0)
            case .left:   return (.pi / 2, 0, .pi / 2)
            }
        }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Atom {
        float3 position;
        float3 color;
        float size;
    };

    struct Uniforms {
        float4x4 mvp;
        float pointSize;
        float maxPointSize;
    };

    struct VSOut {
        float4 position [[position]];
        float  point_size [[point_size]];
        float3 color;
    };

    vertex VSOut vertex_main(const device Atom* atoms [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]],
                             uint id [[vertex_id]]) {
        VSOut out;
        out.position = u.mvp * float4(atoms[id].position, 1.0);
        // Perspective-scaled point size: nearer atoms draw larger.
        out.point_size = clamp(u.pointSize * atoms[id].size / max(out.position.w, 0.1), 1.5, u.maxPointSize);
        out.color = atoms[id].color;
        return out;
    }

    fragment float4 fragment_main(VSOut in [[stage_in]],
                                  float2 pc [[point_coord]]) {
        // Round the point sprite and shade it toward the rim for a sphere cue.
        float2 d = pc - 0.5;
        float r2 = dot(d, d);
        if (r2 > 0.25) discard_fragment();
        float shade = 1.0 - r2 * 2.2;
        return float4(in.color * shade, 1.0);
    }
    """
}

/// Per-element rendering overrides: colour and relative size factor, keyed by
/// element token. Unset elements fall back to the CPK palette and factor 1.
/// The app persists these; video export receives the same style so movies
/// match the window.
public struct AtomStyle {
    public var colors: [String: SIMD3<Float>]
    public var sizes: [String: Float]

    public init(colors: [String: SIMD3<Float>] = [:], sizes: [String: Float] = [:]) {
        self.colors = colors
        self.sizes = sizes
    }

    public func color(for element: String) -> SIMD3<Float> {
        colors[element] ?? AtomPalette.rgb(for: element)
    }

    public func size(for element: String) -> Float {
        sizes[element] ?? 1
    }
}

/// CPK-style element colours (UI-framework-free; the app wraps these in SwiftUI).
public enum AtomPalette {
    public static func rgb(for element: String) -> SIMD3<Float> {
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
}
