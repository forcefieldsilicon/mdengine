import Metal
import simd
import LAMMPSCore

/// Headless trajectory renderer: same shader, normalization, and camera math
/// as the app's interactive view, drawing into an offscreen texture and
/// returning top-down BGRA bytes. Used by video export (app + MCP + CLI).
public final class OffscreenRenderer {
    public struct Camera {
        public var yaw: Float
        public var pitch: Float
        public var distance: Float
        public var pan: SIMD2<Float>
        public var orthographic: Bool
        public var roll: Float
        public init(yaw: Float = 0, pitch: Float = 0, distance: Float = 2.8,
                    pan: SIMD2<Float> = .zero, orthographic: Bool = false,
                    roll: Float = 0) {
            self.yaw = yaw
            self.pitch = pitch
            self.distance = distance
            self.pan = pan
            self.orthographic = orthographic
            self.roll = roll
        }
    }

    public let width: Int
    public let height: Int
    /// Ångströms per model unit — the inverse of the trajectory normalization;
    /// annotations use it to draw a correct scale bar.
    public let angstromsPerModelUnit: Float

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Second pipeline for bond/backbone line primitives; shares the depth
    /// state and the uniform layout with the point pipeline.
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let colorTexture: MTLTexture
    private let depthTexture: MTLTexture
    private let frames: [[Arv]]
    private let center: SIMD3<Float>
    private let scale: Float
    private let pointSize: Float
    private let background: SIMD3<Double>
    private let style: AtomStyle

    public init?(frames: [[Arv]], width: Int, height: Int,
                 pointSize: Float = 14,
                 background: SIMD3<Double> = SIMD3(0.05, 0.05, 0.08),
                 style: AtomStyle = AtomStyle()) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              !frames.isEmpty, frames.contains(where: { !$0.isEmpty }) else { return nil }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height
        self.frames = frames
        self.pointSize = pointSize
        self.background = background
        self.style = style

        // Union bounding box across all frames — one stable scale for the video.
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for frame in frames {
            for a in frame {
                let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                minP = min(minP, p)
                maxP = max(maxP, p)
            }
        }
        let extent = maxP - minP
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        center = (minP + maxP) * 0.5
        scale = maxExtent > 0 ? 1.8 / maxExtent : 1.0
        angstromsPerModelUnit = scale > 0 ? 1 / scale : 0

        guard let library = try? device.makeLibrary(source: RenderCore.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "vertex_main"),
              let fragment = library.makeFunction(name: "fragment_main") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline

        guard let lineLibrary = try? device.makeLibrary(source: RenderCore.lineShaderSource, options: nil),
              let lineVertex = lineLibrary.makeFunction(name: "line_vertex_main"),
              let lineFragment = lineLibrary.makeFunction(name: "line_fragment_main") else { return nil }
        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.vertexFunction = lineVertex
        lineDescriptor.fragmentFunction = lineFragment
        lineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        lineDescriptor.depthAttachmentPixelFormat = .depth32Float
        guard let linePipeline = try? device.makeRenderPipelineState(descriptor: lineDescriptor) else { return nil }
        self.linePipeline = linePipeline

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else { return nil }
        colorTexture = color
        depthTexture = depth
    }

    public var frameCount: Int { frames.count }

    private func clampedIndex(_ i: Int) -> Int { max(0, min(frames.count - 1, i)) }

    /// A frame's atom positions in the renderer's normalized model space —
    /// what `RenderCore.lineVertices` needs so bonds land on the atoms.
    public func modelPositions(frameIndex: Int) -> [SIMD3<Float>] {
        frames[clampedIndex(frameIndex)].map {
            (SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) - center) * scale
        }
    }

    /// The colour each atom is drawn with: the override when it matches the
    /// frame atom-for-atom, otherwise the element style. Half-bonds take
    /// their colours from here, so a bond under an overlay is coloured by the
    /// overlay too.
    public func atomColors(frameIndex: Int, override: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        let frame = frames[clampedIndex(frameIndex)]
        if let override, override.count == frame.count { return override }
        return frame.map { style.color(for: $0.element) }
    }

    /// Render one trajectory frame; returns width*height*4 BGRA bytes, row 0 = top.
    ///
    /// `colors`, when non-nil and exactly as long as the frame's atom count,
    /// replaces the element style colour atom-for-atom (sizes are untouched).
    /// Any other count is ignored — a field of the wrong length must never be
    /// misattributed to the wrong atoms.
    ///
    /// `lines` are bond/backbone vertex pairs already in model space (build
    /// them with `modelPositions` + `RenderCore.lineVertices`); they are drawn
    /// after the atoms, against the same depth buffer.
    public func renderBGRA(frameIndex: Int, camera: Camera,
                           colors: [SIMD3<Float>]? = nil,
                           lines: [RenderCore.LineVertex]? = nil) -> [UInt8]? {
        let i = max(0, min(frames.count - 1, frameIndex))
        let frame = frames[i]
        let override = (colors?.count == frame.count) ? colors : nil
        let gpuAtoms: [RenderCore.RenderAtom] = frame.enumerated().map { n, a in
            let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
            return RenderCore.RenderAtom(position: (p - center) * scale,
                                         color: override?[n] ?? style.color(for: a.element),
                                         size: style.size(for: a.element))
        }
        guard !gpuAtoms.isEmpty,
              let atomBuffer = device.makeBuffer(
                bytes: gpuAtoms,
                length: MemoryLayout<RenderCore.RenderAtom>.stride * gpuAtoms.count,
                options: []) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(background.x, background.y, background.z, 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        let aspect = Float(width) / Float(height)
        let mvp = RenderCore.projection(orthographic: camera.orthographic,
                                        distance: camera.distance, aspect: aspect)
                * RenderCore.viewMatrix(yaw: camera.yaw, pitch: camera.pitch,
                                        distance: camera.distance, pan: camera.pan,
                                        roll: camera.roll)
        // Sprite sizes are in pixels: scale with output height so atoms keep
        // the same visual fraction at 1080p, 4K, or a small GIF.
        let resScale = Float(height) / RenderCore.referenceDrawableHeight
        let base = pointSize * resScale
        var uniforms = RenderCore.Uniforms(
            mvp: mvp,
            pointSize: camera.orthographic ? base / camera.distance : base,
            maxPointSize: 48 * max(resScale, 0.5))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(atomBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderCore.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: gpuAtoms.count)

        if let lines, !lines.isEmpty,
           let lineBuffer = device.makeBuffer(
            bytes: lines,
            length: MemoryLayout<RenderCore.LineVertex>.stride * lines.count,
            options: []) {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderCore.Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count & ~1)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            colorTexture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                                  from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}
