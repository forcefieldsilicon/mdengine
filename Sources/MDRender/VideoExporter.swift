import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd
import LAMMPSCore

/// Turns a trajectory into an MP4 (H.264) or animated GIF through the shared
/// offscreen renderer. Annotations (scale bar + frame counter) are baked by
/// default and can be disabled. Synchronous — call from a background queue.
public enum VideoExporter {
    public enum Format { case mp4, gif }

    public struct Options {
        public var width: Int
        public var height: Int
        public var fps: Int
        /// Render every Nth trajectory frame. 0 = auto (target ~15 s of video).
        public var stride: Int
        public var format: Format
        public var annotations: Bool
        /// Slow cinematic yaw in degrees per second of *video* time; 0 = static.
        public var orbitDegreesPerSecond: Double
        public var camera: OffscreenRenderer.Camera
        public var pointSize: Float
        public var background: SIMD3<Double>
        public var style: AtomStyle

        public init(width: Int = 1920, height: Int = 1080, fps: Int = 30,
                    stride: Int = 0, format: Format = .mp4, annotations: Bool = true,
                    orbitDegreesPerSecond: Double = 0,
                    camera: OffscreenRenderer.Camera = .init(),
                    pointSize: Float = 14,
                    background: SIMD3<Double> = SIMD3(0.05, 0.05, 0.08),
                    style: AtomStyle = AtomStyle()) {
            self.width = width
            self.height = height
            self.fps = fps
            self.stride = stride
            self.format = format
            self.annotations = annotations
            self.orbitDegreesPerSecond = orbitDegreesPerSecond
            self.camera = camera
            self.pointSize = pointSize
            self.background = background
            self.style = style
        }
    }

    public static let targetSeconds = 15.0

    /// Stride that lands a trajectory near the target video length.
    public static func autoStride(frameCount: Int, fps: Int, seconds: Double = targetSeconds) -> Int {
        max(1, Int((Double(frameCount) / (seconds * Double(fps))).rounded()))
    }

    /// Export `frames` to `url`. `progress` (0…1) may return false to cancel.
    /// Returns the number of video frames written.
    @discardableResult
    public static func export(frames: [[Arv]], to url: URL, options: Options,
                              progress: (Double) -> Bool = { _ in true }) throws -> Int {
        // H.264 requires even dimensions.
        let w = options.width & ~1, h = options.height & ~1
        guard let renderer = OffscreenRenderer(frames: frames, width: w, height: h,
                                               pointSize: options.pointSize,
                                               background: options.background,
                                               style: options.style) else {
            throw NSError(domain: "MDRender", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the offscreen renderer (no Metal device, or empty trajectory)."])
        }
        let stride = options.stride > 0 ? options.stride
            : autoStride(frameCount: frames.count, fps: options.fps)
        let indices = Array(Swift.stride(from: 0, to: frames.count, by: stride))
        guard !indices.isEmpty else { throw NSError(domain: "MDRender", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No frames selected."]) }

        try? FileManager.default.removeItem(at: url)
        let yawPerFrame = Float(options.orbitDegreesPerSecond / Double(options.fps) * .pi / 180)

        func frameBytes(_ videoIndex: Int) -> [UInt8]? {
            var camera = options.camera
            camera.yaw += yawPerFrame * Float(videoIndex)
            guard var bytes = renderer.renderBGRA(frameIndex: indices[videoIndex], camera: camera)
            else { return nil }
            if options.annotations {
                annotate(&bytes, width: w, height: h,
                         frame: indices[videoIndex] + 1, of: frames.count,
                         angstromsPerPixel: angstromsPerPixel(renderer: renderer,
                                                              camera: camera, height: h))
            }
            return bytes
        }

        switch options.format {
        case .mp4:
            return try writeMP4(to: url, width: w, height: h, fps: options.fps,
                                count: indices.count, frameBytes: frameBytes, progress: progress)
        case .gif:
            return try writeGIF(to: url, width: w, height: h, fps: options.fps,
                                count: indices.count, frameBytes: frameBytes, progress: progress)
        }
    }

    private static func angstromsPerPixel(renderer: OffscreenRenderer,
                                          camera: OffscreenRenderer.Camera, height: Int) -> Double {
        let visibleModel = 2 * Double(camera.distance) * tan(Double(RenderCore.fovY) / 2)
        return visibleModel * Double(renderer.angstromsPerModelUnit) / Double(height)
    }

    /// Render one trajectory frame to a PNG (same camera/style/annotation
    /// options as video). Returns the pixel size written.
    @discardableResult
    public static func exportPNG(frames: [[Arv]], frameIndex: Int, to url: URL,
                                 options: Options) throws -> (width: Int, height: Int) {
        let w = options.width & ~1, h = options.height & ~1
        guard let renderer = OffscreenRenderer(frames: frames, width: w, height: h,
                                               pointSize: options.pointSize,
                                               background: options.background,
                                               style: options.style) else {
            throw NSError(domain: "MDRender", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the offscreen renderer (no Metal device, or empty trajectory)."])
        }
        let i = max(0, min(frames.count - 1, frameIndex))
        guard var bytes = renderer.renderBGRA(frameIndex: i, camera: options.camera) else {
            throw NSError(domain: "MDRender", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Render failed."])
        }
        if options.annotations {
            annotate(&bytes, width: w, height: h, frame: i + 1, of: frames.count,
                     angstromsPerPixel: angstromsPerPixel(renderer: renderer,
                                                          camera: options.camera, height: h))
        }
        guard let image = cgImage(bytes, w, h),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MDRender", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Could not create PNG at \(url.path)"])
        }
        try? FileManager.default.removeItem(at: url)
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MDRender", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "PNG finalize failed"])
        }
        return (w, h)
    }

    /// "Best visibility" auto-style: the most abundant element is the
    /// substrate and keeps its palette color at 1×; every minority species is
    /// enlarged (1.8×) and, if its palette color reads close to the
    /// substrate's, recolored to contrast (red, else cyan).
    public static func contrastStyle(for frame: [Arv]) -> AtomStyle {
        var counts: [String: Int] = [:]
        for a in frame { counts[a.element, default: 0] += 1 }
        guard let majority = counts.max(by: { $0.value < $1.value })?.key else { return AtomStyle() }
        let majorityColor = AtomPalette.rgb(for: majority)
        var style = AtomStyle()
        let red = SIMD3<Float>(1.0, 0.2, 0.18)
        let cyan = SIMD3<Float>(0.2, 0.9, 1.0)
        for element in counts.keys where element != majority {
            style.sizes[element] = 1.8
            let own = AtomPalette.rgb(for: element)
            if simd_distance(own, majorityColor) < 0.45 {
                style.colors[element] = simd_distance(majorityColor, red) < 0.6 ? cyan : red
            }
        }
        return style
    }

    // MARK: - MP4

    private static func writeMP4(to url: URL, width: Int, height: Int, fps: Int, count: Int,
                                 frameBytes: (Int) -> [UInt8]?,
                                 progress: (Double) -> Bool) throws -> Int {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "MDRender", code: 3) }
        writer.startSession(atSourceTime: .zero)

        var written = 0
        for i in 0..<count {
            guard progress(Double(i) / Double(count)) else { break }
            guard let bytes = frameBytes(i) else { continue }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard let buffer = maybeBuffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let dst = CVPixelBufferGetBaseAddress(buffer)!
            let dstStride = CVPixelBufferGetBytesPerRow(buffer)
            bytes.withUnsafeBytes { src in
                for row in 0..<height {
                    memcpy(dst + row * dstStride, src.baseAddress! + row * width * 4, width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            written += 1
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw writer.error ?? NSError(domain: "MDRender", code: 4) }
        _ = progress(1)
        return written
    }

    // MARK: - GIF

    private static func writeGIF(to url: URL, width: Int, height: Int, fps: Int, count: Int,
                                 frameBytes: (Int) -> [UInt8]?,
                                 progress: (Double) -> Bool) throws -> Int {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         count, nil) else {
            throw NSError(domain: "MDRender", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Could not create GIF at \(url.path)"])
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)],
        ] as CFDictionary

        var written = 0
        for i in 0..<count {
            guard progress(Double(i) / Double(count)) else { break }
            guard let bytes = frameBytes(i), let image = cgImage(bytes, width, height) else { continue }
            CGImageDestinationAddImage(dest, image, frameProps)
            written += 1
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MDRender", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "GIF finalize failed"])
        }
        _ = progress(1)
        return written
    }

    private static func cgImage(_ bytes: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: - Annotations (scale bar bottom-left, frame counter top-right)

    private static func annotate(_ bytes: inout [UInt8], width: Int, height: Int,
                                 frame: Int, of total: Int, angstromsPerPixel: Double) {
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            // Buffer is top-down; CG is bottom-up. All positions below are in
            // CG coordinates (origin bottom-left) — text drawn via CoreText is
            // upright in the final image because we flip once for the buffer.
            let s = CGFloat(height) / 1080          // annotation scale
            let margin = 24 * s
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)

            // Scale bar
            let nice = RenderCore.niceLength(targetAngstroms: Double(width) * 0.09 * angstromsPerPixel)
            let barWidth = CGFloat(nice / angstromsPerPixel)
            let barY = margin
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.fill(CGRect(x: margin - 10 * s, y: barY - 10 * s,
                            width: barWidth + 20 * s, height: 56 * s))
            ctx.setFillColor(white)
            ctx.fill(CGRect(x: margin, y: barY, width: barWidth, height: 3 * s))
            ctx.fill(CGRect(x: margin, y: barY, width: 2.5 * s, height: 12 * s))
            ctx.fill(CGRect(x: margin + barWidth - 2.5 * s, y: barY, width: 2.5 * s, height: 12 * s))
            let barLabel = nice == nice.rounded() ? String(format: "%.0f Å", nice)
                                                  : String(format: "%.1f Å", nice)
            drawText(barLabel, in: ctx, at: CGPoint(x: margin, y: barY + 16 * s), size: 22 * s, color: white)

            // Frame counter
            let counter = "frame \(frame)/\(total)"
            let counterSize = 20 * s
            let textWidth = CGFloat(counter.count) * counterSize * 0.62
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.fill(CGRect(x: CGFloat(width) - margin - textWidth - 12 * s,
                            y: CGFloat(height) - margin - counterSize * 1.5,
                            width: textWidth + 16 * s, height: counterSize * 1.8))
            drawText(counter, in: ctx,
                     at: CGPoint(x: CGFloat(width) - margin - textWidth,
                                 y: CGFloat(height) - margin - counterSize * 1.2),
                     size: counterSize, color: white)
        }
    }

    private static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint,
                                 size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
