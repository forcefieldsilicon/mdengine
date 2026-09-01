import Metal
import MetalKit
import simd
import LAMMPSCore

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    // Trajectory: frames share one normalization (union bounding box) so the
    // camera scale is stable while scrubbing. GPU atom arrays are built
    // per-frame on demand — precomputing all frames of a long trajectory
    // costs hundreds of MB for nothing.
    private var frames: [[Arv]] = []
    private var center = SIMD3<Float>(0, 0, 0)
    private var scale: Float = 1
    private var frameBuffers: [Int: MTLBuffer] = [:]
    private var cacheBuffers = true
    private var currentFrame = 0
    private var atomBuffer: MTLBuffer?
    private var atomCount: Int = 0

    // Orbit camera around the (already centred/normalised) structure.
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance: Float = Renderer.homeDistance
    private var pan = SIMD2<Float>(0, 0)
    private static let homeDistance: Float = 2.8

    /// One vertex per atom: normalized model-space position + RGB colour.
    private struct GPUAtom {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    /// Must match the `Uniforms` struct in the shader source below.
    private struct Uniforms {
        var mvp: simd_float4x4
        var pointSize: Float
    }

    init(view: MTKView) {
        self.device = view.device!
        self.commandQueue = device.makeCommandQueue()!

        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.05, 0.05, 0.08, 1.0)
        view.clearDepth = 1.0

        // Compile the shader from source at runtime so we don't depend on how
        // SwiftPM bundles .metal files (Resources vs. compiled metallib).
        let library = try! device.makeLibrary(source: Renderer.shaderSource, options: nil)
        let vertex = library.makeFunction(name: "vertex_main")!
        let fragment = library.makeFunction(name: "fragment_main")!

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        self.pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        super.init()
    }

    /// Load a whole trajectory: map raw Ångström coordinates into a unit-ish
    /// model space ([-0.9, 0.9] on the longest axis of the UNION bounding box,
    /// so every frame shares one scale) and assign per-element colours.
    func setTrajectory(_ trajectory: [[Arv]]) {
        frameBuffers.removeAll()
        atomBuffer = nil
        atomCount = 0
        guard !trajectory.isEmpty, trajectory.contains(where: { !$0.isEmpty }) else {
            frames = []
            return
        }

        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var totalAtoms = 0
        for frame in trajectory {
            totalAtoms += frame.count
            for a in frame {
                let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                minP = min(minP, p)
                maxP = max(maxP, p)
            }
        }
        let extent = maxP - minP
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        frames = trajectory
        center = (minP + maxP) * 0.5
        // Uniform scale preserves aspect ratio; 1.8 leaves a small margin.
        scale = maxExtent > 0 ? 1.8 / maxExtent : 1.0
        // Cache per-frame buffers only while the whole trajectory fits well
        // under GPU memory; otherwise rebuild the buffer on each frame change.
        cacheBuffers = totalAtoms * MemoryLayout<GPUAtom>.stride < 512 << 20
        currentFrame = min(currentFrame, frames.count - 1)
        publishViewportScale()
        showFrame(currentFrame)
    }

    func showFrame(_ index: Int) {
        guard !frames.isEmpty else { return }
        let i = max(0, min(frames.count - 1, index))
        currentFrame = i
        if let cached = frameBuffers[i] {
            atomBuffer = cached
            atomCount = frames[i].count
            return
        }
        let gpuAtoms: [GPUAtom] = frames[i].map { a in
            let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
            return GPUAtom(position: (p - center) * scale,
                           color: ElementColors.rgb(for: a.element))
        }
        atomCount = gpuAtoms.count
        atomBuffer = gpuAtoms.isEmpty ? nil
            : device.makeBuffer(bytes: gpuAtoms,
                                length: MemoryLayout<GPUAtom>.stride * gpuAtoms.count,
                                options: [])
        if cacheBuffers, let buffer = atomBuffer { frameBuffers[i] = buffer }
    }

    // MARK: - Camera controls

    /// Rotate around the structure. Deltas are mouse-drag distances in points.
    func orbit(dx: Float, dy: Float) {
        let s = Renderer.pref("orbitSensitivity", default: 8) * 0.001
        yaw += dx * s
        pitch += dy * s
        let limit = Float.pi / 2 - 0.02   // stop just short of the poles
        pitch = max(-limit, min(limit, pitch))
    }

    /// factor > 1 moves the camera closer, < 1 pulls it back.
    func zoom(byFactor factor: Float) {
        let f = max(0.2, factor)
        distance = max(1.1, min(12, distance / f))
        publishViewportScale()
    }

    /// Translate the view target; deltas are mouse-drag distances in points.
    /// Scaled by camera distance so the structure tracks the cursor at any zoom.
    func pan(dx: Float, dy: Float) {
        let s = 0.0011 * distance
        pan.x += dx * s
        pan.y -= dy * s
        pan = clamp(pan, min: SIMD2<Float>(repeating: -4), max: SIMD2<Float>(repeating: 4))
    }

    func resetCamera() {
        yaw = 0
        pitch = 0
        pan = SIMD2<Float>(0, 0)
        distance = Renderer.homeDistance
        publishViewportScale()
    }

    private func publishViewportScale() {
        ViewportScale.shared.update(distance: distance,
                                    angstromsPerModelUnit: scale > 0 ? 1 / scale : 0)
    }

    /// Settings written by SettingsView via @AppStorage; defaults must match.
    private static func pref(_ key: String, default def: Double) -> Float {
        Float(UserDefaults.standard.object(forKey: key) as? Double ?? def)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Always encode a pass, even with no atoms: an early return would leave
        // the view never painted (window background shows through), which reads
        // as a broken blank window instead of an intentional empty scene.
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let bgBrightness = Double(Renderer.pref("backgroundBrightness", default: 0.05))
        view.clearColor = MTLClearColorMake(bgBrightness, bgBrightness, bgBrightness + 0.03, 1.0)

        guard atomCount > 0, let atomBuffer = atomBuffer else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let orthographic = UserDefaults.standard.bool(forKey: "orthographicProjection")
        // Orthographic frames the same height the perspective camera would see
        // at the current distance, so zoom keeps working and switching
        // projections holds the framing.
        let projection = orthographic
            ? Renderer.orthographic(height: 2 * distance * tan(Float.pi / 8),
                                    aspect: aspect, near: 0.05, far: 100)
            : Renderer.perspective(fovY: .pi / 4, aspect: aspect, near: 0.05, far: 100)
        let viewMatrix = Renderer.translation(pan.x, pan.y, -distance)
                       * Renderer.rotationX(pitch)
                       * Renderer.rotationY(yaw)
        // Base size is divided by clip-space w in the shader, so atoms grow as
        // the camera closes in and nearer atoms render larger than far ones.
        // Orthographic w is 1, so pre-divide by distance to keep sizes matched.
        let baseSize = Renderer.pref("atomPointSize", default: 14)
        var uniforms = Uniforms(mvp: projection * viewMatrix,
                                pointSize: orthographic ? baseSize / distance : baseSize)


        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(atomBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: atomCount)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Matrices (column-major, right-handed, Metal [0,1] depth)

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
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

    private static func orthographic(height: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let w = height * aspect, h = height
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / w, 0, 0, 0),
            SIMD4<Float>(0, 2 / h, 0, 0),
            SIMD4<Float>(0, 0, -1 / (far - near), 0),
            SIMD4<Float>(0, 0, -near / (far - near), 1)
        ))
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Atom {
        float3 position;
        float3 color;
    };

    struct Uniforms {
        float4x4 mvp;
        float pointSize;
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
        out.point_size = clamp(u.pointSize / max(out.position.w, 0.1), 1.5, 48.0);
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
