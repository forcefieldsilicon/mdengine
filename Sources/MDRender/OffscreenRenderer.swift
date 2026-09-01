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

    /// Render one trajectory frame; returns width*height*4 BGRA bytes, row 0 = top.
    public func renderBGRA(frameIndex: Int, camera: Camera) -> [UInt8]? {
        let i = max(0, min(frames.count - 1, frameIndex))
        let gpuAtoms: [RenderCore.RenderAtom] = frames[i].map { a in
            let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
            return RenderCore.RenderAtom(position: (p - center) * scale,
                                         color: style.color(for: a.element),
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
