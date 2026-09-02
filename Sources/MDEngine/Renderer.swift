import Metal
import MetalKit
import simd
import LAMMPSCore
import MDRender

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
    // Home view = isometric (the app default).
    private var yaw: Float = RenderCore.ViewPreset.isometric.viewAngles.yaw
    private var pitch: Float = RenderCore.ViewPreset.isometric.viewAngles.pitch
    private var roll: Float = 0
    private var distance: Float = Renderer.homeDistance
    private var pan = SIMD2<Float>(0, 0)
    private static let homeDistance: Float = 2.8

    init(view: MTKView) {
        self.device = view.device!
        self.commandQueue = device.makeCommandQueue()!

        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.05, 0.05, 0.08, 1.0)
        view.clearDepth = 1.0

        // Compile the shader from source at runtime so we don't depend on how
        // SwiftPM bundles .metal files (Resources vs. compiled metallib).
        let library = try! device.makeLibrary(source: RenderCore.shaderSource, options: nil)
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
        cacheBuffers = totalAtoms * MemoryLayout<RenderCore.RenderAtom>.stride < 512 << 20
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
        let gpuAtoms: [RenderCore.RenderAtom] = frames[i].map { a in
            let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
            return RenderCore.RenderAtom(position: (p - center) * scale,
                                         color: style.color(for: a.element),
                                         size: style.size(for: a.element))
        }
        atomCount = gpuAtoms.count
        atomBuffer = gpuAtoms.isEmpty ? nil
            : device.makeBuffer(bytes: gpuAtoms,
                                length: MemoryLayout<RenderCore.RenderAtom>.stride * gpuAtoms.count,
                                options: [])
        if cacheBuffers, let buffer = atomBuffer { frameBuffers[i] = buffer }
    }

    // MARK: - Per-element style

    private var style = ElementStyleStore.currentStyle()

    /// Re-read persisted element overrides and rebuild GPU data.
    func reloadStyle() {
        style = ElementStyleStore.currentStyle()
        frameBuffers.removeAll()
        showFrame(currentFrame)
    }

    // MARK: - Camera controls

    /// Rotate around the structure. Deltas are mouse-drag distances in points.
    func orbit(dx: Float, dy: Float) {
        let s = Renderer.pref("orbitSensitivity", default: 8) * 0.001
        yaw += dx * s
        pitch += dy * s
        let limit = Float.pi / 2 - 0.02   // stop just short of the poles
        pitch = max(-limit, min(limit, pitch))
        publishViewportScale()
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
        publishViewportScale()
    }

    func resetCamera() {
        setView(.isometric)
        distance = Renderer.homeDistance
    }

    /// Snap to a canonical view (Top/Front/…): exact angles, pan cleared,
    /// zoom kept. Preset pitches may exceed the interactive orbit clamp —
    /// the next orbit drag re-clamps, which is the CAD-usual behavior.
    func setView(_ preset: RenderCore.ViewPreset) {
        let v = preset.viewAngles
        yaw = v.yaw
        pitch = v.pitch
        roll = v.roll
        pan = SIMD2<Float>(0, 0)
        publishViewportScale()
    }

    /// Where this renderer's camera state goes: the main pane publishes to
    /// ViewportScale.shared (scale bar + video export); each extra pane gets
    /// its own instance so its scale bar tracks its own zoom. nil = nobody.
    var scaleSink: ViewportScale? = ViewportScale.shared

    private func publishViewportScale() {
        scaleSink?.update(distance: distance,
                          angstromsPerModelUnit: scale > 0 ? 1 / scale : 0,
                          yaw: yaw, pitch: pitch, pan: pan, roll: roll)
    }

    /// Effective background = stored hue × brightness slider. Defaults
    /// reproduce the original near-black blue (0.63,0.63,1.0 × 0.08).
    static func backgroundColor() -> SIMD3<Double> {
        let brightness = Double(pref("backgroundBrightness", default: 0.08))
        let stored = UserDefaults.standard.string(forKey: "backgroundColor") ?? "0.63 0.63 1.0"
        let p = stored.split(separator: " ").compactMap { Double($0) }
        let hue = p.count == 3 ? SIMD3<Double>(p[0], p[1], p[2]) : SIMD3<Double>(0.63, 0.63, 1.0)
        return hue * brightness
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

        let bg = Renderer.backgroundColor()
        view.clearColor = MTLClearColorMake(bg.x, bg.y, bg.z, 1.0)

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
        let projection = RenderCore.projection(orthographic: orthographic,
                                               distance: distance, aspect: aspect)
        let viewMatrix = RenderCore.viewMatrix(yaw: yaw, pitch: pitch,
                                               distance: distance, pan: pan, roll: roll)
        // Base size is divided by clip-space w in the shader, so atoms grow as
        // the camera closes in and nearer atoms render larger than far ones.
        // Orthographic w is 1, so pre-divide by distance to keep sizes matched.
        let baseSize = Renderer.pref("atomPointSize", default: 14)
        var uniforms = RenderCore.Uniforms(mvp: projection * viewMatrix,
                                           pointSize: orthographic ? baseSize / distance : baseSize)


        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(atomBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderCore.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: atomCount)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

}
