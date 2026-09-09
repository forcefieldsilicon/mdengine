import simd
import Foundation
import LAMMPSCore

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

    /// One vertex per line endpoint; layout must match `Line` in the line
    /// shader. Bonds and the backbone trace share the buffer — they differ
    /// only in colour, so one draw call covers both.
    public struct LineVertex {
        public var position: SIMD3<Float>
        public var color: SIMD3<Float>
        public init(position: SIMD3<Float>, color: SIMD3<Float>) {
            self.position = position
            self.color = color
        }
    }

    /// Backbone traces are drawn in a fixed light grey rather than in the
    /// chain's atom colours: the trace is a schematic, and colouring it per
    /// chain would compete with whatever the overlay is already saying with
    /// colour. 0.85 reads clearly on the app's near-black default background
    /// and stays visible on a light one.
    public static let backboneColor = SIMD3<Float>(repeating: 0.85)

    /// Line geometry for one frame, in the SAME model space as the render
    /// atoms (caller normalizes positions first).
    ///
    /// Each bond becomes two *half* segments meeting at the midpoint, coloured
    /// by their own atom — the standard half-bond convention, so an O–H stick
    /// reads red then white instead of picking one atom's colour and lying
    /// about the other. `colors` shorter than `positions` falls back to white,
    /// and out-of-range indices are skipped (a stale bond set against a
    /// smaller frame must never crash the renderer).
    public static func lineVertices(bonds: BondSet,
                                    positions: [SIMD3<Float>],
                                    colors: [SIMD3<Float>]) -> [LineVertex] {
        let n = positions.count
        guard n > 0 else { return [] }
        let white = SIMD3<Float>(repeating: 1)
        func color(_ i: Int) -> SIMD3<Float> { i < colors.count ? colors[i] : white }

        var out: [LineVertex] = []
        out.reserveCapacity(bonds.pairs.count * 2 + bonds.backbone.reduce(0) { $0 + $1.count * 2 })

        for k in stride(from: 0, to: bonds.pairs.count - 1, by: 2) {
            let i = Int(bonds.pairs[k]), j = Int(bonds.pairs[k + 1])
            guard i < n, j < n else { continue }
            let a = positions[i], b = positions[j]
            let mid = (a + b) * 0.5
            out.append(LineVertex(position: a, color: color(i)))
            out.append(LineVertex(position: mid, color: color(i)))
            out.append(LineVertex(position: mid, color: color(j)))
            out.append(LineVertex(position: b, color: color(j)))
        }

        for chain in bonds.backbone where chain.count >= 2 {
            for k in 0..<(chain.count - 1) {
                let i = Int(chain[k]), j = Int(chain[k + 1])
                guard i < n, j < n else { continue }
                out.append(LineVertex(position: positions[i], color: backboneColor))
                out.append(LineVertex(position: positions[j], color: backboneColor))
            }
        }
        return out
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

    /// Bonds and backbone. Same `Uniforms` (same mvp, same buffer index) as
    /// the atom shader, so one uniform upload serves both passes. The
    /// fragment shader dims the far end slightly with clip-space depth, which
    /// is the cheapest cue that keeps a dense bond cage from reading flat.
    public static let lineShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Line {
        float3 position;
        float3 color;
    };

    struct Uniforms {
        float4x4 mvp;
        float pointSize;
        float maxPointSize;
    };

    struct LineOut {
        float4 position [[position]];
        float3 color;
        float  depth;
    };

    vertex LineOut line_vertex_main(const device Line* lines [[buffer(0)]],
                                    constant Uniforms& u [[buffer(1)]],
                                    uint id [[vertex_id]]) {
        LineOut out;
        out.position = u.mvp * float4(lines[id].position, 1.0);
        out.color = lines[id].color;
        // 0 at the near plane, 1 at the far one; clamped so an orthographic
        // camera (w == 1) still lands in range.
        out.depth = clamp(out.position.z / max(out.position.w, 0.0001), 0.0, 1.0);
        return out;
    }

    fragment float4 line_fragment_main(LineOut in [[stage_in]]) {
        float shade = 1.0 - 0.35 * in.depth;
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
