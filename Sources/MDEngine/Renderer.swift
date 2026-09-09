import Metal
import MetalKit
import simd
import LAMMPSCore
import MDRender

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// Bond/backbone line primitives (GJOB-145). Same uniforms, same depth
    /// state as the atoms; drawn after them so sticks sit on the sprites.
    private let linePipelineState: MTLRenderPipelineState
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

    // MARK: - Dirty flag + cached prefs (design §1b, GJOB-133)

    /// The display link draws only while this is set (plus a ~1 Hz safety
    /// redraw). Every camera/frame/style/prefs change sets it; draw() clears it.
    private(set) var needsRedraw = true
    func markDirty() { needsRedraw = true }

    /// Prefs used per draw, read once and refreshed on UserDefaults changes —
    /// not re-read (and re-parsed) 60–120 times a second per pane.
    private struct Prefs {
        var background: SIMD3<Double>
        var orthographic: Bool
        var pointSize: Float
        var orbitSensitivity: Float
    }
    private var prefs = Renderer.readPrefs()
    private var prefsObserver: NSObjectProtocol?
    private static func readPrefs() -> Prefs {
        Prefs(background: backgroundColor(),
              orthographic: UserDefaults.standard.bool(forKey: "orthographicProjection"),
              pointSize: pref("atomPointSize", default: 14),
              orbitSensitivity: pref("orbitSensitivity", default: 8))
    }

    /// GPU buffers are built off the main thread; only the newest wanted
    /// frame is worth finishing (latest wins while scrubbing).
    private let buildQueue = DispatchQueue(label: "mdengine.render.buffers", qos: .userInteractive)
    private let wantLock = NSLock()
    private var wanted = (frame: 0, generation: 0)
    private var trajectoryGeneration = 0

    /// Per-atom colours from the overlay tool (design §1: one new colour
    /// source). Applies to whichever frame is shown while the counts match;
    /// nil = element colours. Cached frame buffers are colour-specific, so a
    /// change drops the cache and rebuilds the current frame off main.
    private var colorOverride: [SIMD3<Float>]?
    func setColorOverride(_ colors: [SIMD3<Float>]?) {
        // Cached buffers carry element colours; while an override is active
        // frames are rebuilt per show (≈1 ms off main) and NOT cached, so a
        // 4 Hz colour refresh never churns 30 Metal buffers through dealloc.
        let hadOverride = colorOverride != nil
        colorOverride = colors
        if hadOverride != (colors != nil) { frameBuffers.removeAll() }
        showFrame(currentFrame)
        // Half-bonds are coloured by their atoms, so an overlay change
        // recolours the sticks too.
        if bondSet != nil { rebuildLineBuffer() }
    }

    // MARK: - Bonds + backbone (GJOB-145)

    /// Perceived topology for the frame on screen; nil = points only. Kept
    /// here (not re-derived per draw) and turned into a line buffer off the
    /// main thread, exactly like the atom buffer.
    private var bondSet: BondSet?
    /// Stick colours supplied with the set; nil = fall back to whatever the
    /// atoms are drawn with (overlay override, else element colours).
    private var bondColors: [SIMD3<Float>]?
    private var lineBuffer: MTLBuffer?
    private var lineVertexCount = 0
    private var bondsWanted = 0

    /// Hand the renderer a bond set for the CURRENT frame. `colors` overrides
    /// the stick colours; nil means "use what the renderer already draws
    /// atoms with" — the overlay colours when one is active, element colours
    /// otherwise. A nil `set` clears the lines.
    ///
    /// The set is not tied to a frame index on purpose: while the model is
    /// still perceiving bonds for a new frame the previous sticks stay up,
    /// which reads as slightly stale geometry rather than a flicker to bare
    /// points on every playback tick.
    func setBonds(_ set: BondSet?, colors: [SIMD3<Float>]? = nil) {
        bondSet = set
        bondColors = colors
        guard set != nil else {
            bondsWanted += 1                 // cancel any build in flight
            lineBuffer = nil
            lineVertexCount = 0
            markDirty()
            return
        }
        rebuildLineBuffer()
    }

    private func rebuildLineBuffer() {
        guard let set = bondSet, !set.isEmpty, frames.indices.contains(currentFrame) else { return }
        bondsWanted += 1
        let token = bondsWanted
        let generation = trajectoryGeneration
        let frame = frames[currentFrame]     // copy-on-write: no atom copy
        let center = center, scale = scale, style = style, device = device
        let supplied = bondColors?.count == frame.count ? bondColors : nil
        let override = supplied ?? (colorOverride?.count == frame.count ? colorOverride : nil)
        buildQueue.async { [weak self] in
            guard let self else { return }
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(frame.count)
            var colors: [SIMD3<Float>] = []
            colors.reserveCapacity(frame.count)
            for (n, a) in frame.enumerated() {
                let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                positions.append((p - center) * scale)
                colors.append(override?[n] ?? style.color(for: a.element))
            }
            let vertices = RenderCore.lineVertices(bonds: set, positions: positions, colors: colors)
            let buffer = vertices.isEmpty ? nil
                : device.makeBuffer(bytes: vertices,
                                    length: MemoryLayout<RenderCore.LineVertex>.stride * vertices.count,
                                    options: [])
            DispatchQueue.main.async {
                // Latest wins: a newer set (or a new file) discards this one.
                guard self.bondsWanted == token, self.trajectoryGeneration == generation else { return }
                self.lineBuffer = buffer
                self.lineVertexCount = vertices.count & ~1
                self.markDirty()
            }
        }
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
        let library = try! device.makeLibrary(source: RenderCore.shaderSource, options: nil)
        let vertex = library.makeFunction(name: "vertex_main")!
        let fragment = library.makeFunction(name: "fragment_main")!

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        self.pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)

        let lineLibrary = try! device.makeLibrary(source: RenderCore.lineShaderSource, options: nil)
        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.vertexFunction = lineLibrary.makeFunction(name: "line_vertex_main")!
        lineDescriptor.fragmentFunction = lineLibrary.makeFunction(name: "line_fragment_main")!
        lineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        lineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        self.linePipelineState = try! device.makeRenderPipelineState(descriptor: lineDescriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        super.init()
        prefsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.prefs = Renderer.readPrefs()
                self?.markDirty()
            }
    }

    deinit {
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    /// Load a whole trajectory: map raw Ångström coordinates into a unit-ish
    /// model space ([-0.9, 0.9] on the longest axis of the UNION bounding box,
    /// so every frame shares one scale) and assign per-element colours.
    func setTrajectory(_ trajectory: [[Arv]]) {
        frameBuffers.removeAll()
        atomBuffer = nil
        atomCount = 0
        trajectoryGeneration += 1
        // Line vertices were built against the OLD centre/scale; keeping them
        // would scatter sticks across the new structure.
        bondSet = nil
        bondColors = nil
        lineBuffer = nil
        lineVertexCount = 0
        bondsWanted += 1
        markDirty()
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
        // The first frame of a new file builds synchronously so the load
        // never flashes an empty scene; every later frame builds off main.
        showFrame(currentFrame, synchronous: true)
    }

    func showFrame(_ index: Int, synchronous: Bool = false) {
        guard !frames.isEmpty else { return }
        let i = max(0, min(frames.count - 1, index))
        currentFrame = i
        let generation = trajectoryGeneration
        wantLock.lock(); wanted = (i, generation); wantLock.unlock()
        if let cached = frameBuffers[i] {
            atomBuffer = cached
            atomCount = frames[i].count
            markDirty()
            return
        }
        let frame = frames[i]           // copy-on-write: no atom copy here
        let center = center, scale = scale, style = style, device = device
        let override = colorOverride?.count == frame.count ? colorOverride : nil
        let cache = cacheBuffers && override == nil
        let build: () -> (MTLBuffer?, Double) = {
            let t0 = DispatchTime.now().uptimeNanoseconds
            var gpuAtoms: [RenderCore.RenderAtom] = []
            gpuAtoms.reserveCapacity(frame.count)
            for (n, a) in frame.enumerated() {
                let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                gpuAtoms.append(RenderCore.RenderAtom(position: (p - center) * scale,
                                                      color: override?[n] ?? style.color(for: a.element),
                                                      size: style.size(for: a.element)))
            }
            let buffer = gpuAtoms.isEmpty ? nil
                : device.makeBuffer(bytes: gpuAtoms,
                                    length: MemoryLayout<RenderCore.RenderAtom>.stride * gpuAtoms.count,
                                    options: [])
            return (buffer, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        if synchronous {
            let (buffer, _) = build()
            atomBuffer = buffer
            atomCount = frame.count
            if cache, let buffer { frameBuffers[i] = buffer }
            markDirty()
            return
        }
        buildQueue.async { [weak self] in
            guard let self else { return }
            self.wantLock.lock()
            let stillWanted = self.wanted == (i, generation)
            self.wantLock.unlock()
            guard stillWanted else { return }          // scrubbed past it: skip
            let (buffer, ms) = build()
            DispatchQueue.main.async {
                guard self.trajectoryGeneration == generation else { return }
                if cache, let buffer { self.frameBuffers[i] = buffer }
                if PerfMonitor.isEnabled { PerfMonitor.shared.recordBufferBuild(ms: ms) }
                self.wantLock.lock()
                let current = self.wanted.frame == i
                self.wantLock.unlock()
                guard current else { return }
                self.atomBuffer = buffer
                self.atomCount = frame.count
                self.markDirty()
            }
        }
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
        let s = prefs.orbitSensitivity * 0.001
        yaw += dx * s
        pitch += dy * s
        let limit = Float.pi / 2 - 0.02   // stop just short of the poles
        pitch = max(-limit, min(limit, pitch))
        publishViewportScale()
        markDirty()
    }

    /// factor > 1 moves the camera closer, < 1 pulls it back.
    func zoom(byFactor factor: Float) {
        let f = max(0.2, factor)
        distance = max(1.1, min(12, distance / f))
        publishViewportScale()
        markDirty()
    }

    /// Translate the view target; deltas are mouse-drag distances in points.
    /// Scaled by camera distance so the structure tracks the cursor at any zoom.
    func pan(dx: Float, dy: Float) {
        let s = 0.0011 * distance
        pan.x += dx * s
        pan.y -= dy * s
        pan = clamp(pan, min: SIMD2<Float>(repeating: -4), max: SIMD2<Float>(repeating: 4))
        publishViewportScale()
        markDirty()
    }

    func resetCamera() {
        setView(.isometric)
        distance = Renderer.homeDistance
        markDirty()
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
        markDirty()
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { markDirty() }

    func draw(in view: MTKView) {
        // Always encode a pass, even with no atoms: an early return would leave
        // the view never painted (window background shows through), which reads
        // as a broken blank window instead of an intentional empty scene.
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        // A pass is being encoded: the scene is clean from here on. (If the
        // guard above failed we stay dirty and retry on the next tick.)
        needsRedraw = false
        let t0 = PerfMonitor.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if PerfMonitor.isEnabled {
                let micros = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
                PerfMonitor.shared.recordDraw(pane: ObjectIdentifier(self), micros: micros)
            }
        }

        let bg = prefs.background
        view.clearColor = MTLClearColorMake(bg.x, bg.y, bg.z, 1.0)

        guard atomCount > 0, let atomBuffer = atomBuffer else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let orthographic = prefs.orthographic
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
        let baseSize = prefs.pointSize
        var uniforms = RenderCore.Uniforms(mvp: projection * viewMatrix,
                                           pointSize: orthographic ? baseSize / distance : baseSize)


        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(atomBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderCore.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: atomCount)

        if lineVertexCount > 0, let lineBuffer {
            encoder.setRenderPipelineState(linePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderCore.Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVertexCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

}
