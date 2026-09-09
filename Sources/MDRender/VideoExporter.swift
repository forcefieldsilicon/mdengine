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
        /// Per-atom field overlay: asked for the field of one *trajectory*
        /// frame index (not the video frame number). nil field, or one whose
        /// value count differs from that frame's atom count, renders normally.
        public var overlay: ((_ trajectoryFrameIndex: Int) -> PerAtomField?)?
        /// Perceived topology for one *trajectory* frame index. nil (the
        /// default) exports points only — exactly as before this existed.
        /// A closure, not a value: perception of a long trajectory is done
        /// frame by frame as the export walks it, never all at once.
        public var bonds: ((_ trajectoryFrameIndex: Int) -> BondSet?)?
        /// Draw the Cα trace as well as (or instead of) the bonds. The bond
        /// sticks themselves come from `bonds`; a caller that wants the trace
        /// alone returns a BondSet with empty `pairs`.
        public var showBackbone: Bool

        public init(width: Int = 1920, height: Int = 1080, fps: Int = 30,
                    stride: Int = 0, format: Format = .mp4, annotations: Bool = true,
                    orbitDegreesPerSecond: Double = 0,
                    camera: OffscreenRenderer.Camera = .init(),
                    pointSize: Float = 14,
                    background: SIMD3<Double> = SIMD3(0.05, 0.05, 0.08),
                    style: AtomStyle = AtomStyle(),
                    overlay: ((_ trajectoryFrameIndex: Int) -> PerAtomField?)? = nil,
                    bonds: ((_ trajectoryFrameIndex: Int) -> BondSet?)? = nil,
                    showBackbone: Bool = false) {
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
            self.overlay = overlay
            self.bonds = bonds
            self.showBackbone = showBackbone
        }
    }

    /// The line geometry for one trajectory frame, in the renderer's model
    /// space — nil when no bond provider is set or it has nothing for this
    /// frame. `showBackbone == false` drops the trace but keeps the sticks.
    private static func lines(renderer: OffscreenRenderer, options: Options,
                              trajectoryIndex: Int,
                              overrideColors: [SIMD3<Float>]?,
                              bonds: BondSet? = nil) -> [RenderCore.LineVertex]? {
        guard var set = bonds ?? options.bonds?(trajectoryIndex) else { return nil }
        if !options.showBackbone { set.backbone = [] }
        guard !set.isEmpty else { return nil }
        return RenderCore.lineVertices(
            bonds: set,
            positions: renderer.modelPositions(frameIndex: trajectoryIndex),
            colors: renderer.atomColors(frameIndex: trajectoryIndex, override: overrideColors))
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
            let trajectoryIndex = indices[videoIndex]
            // A field of the wrong length colours nothing, so it must not
            // put a legend on the frame either.
            let field = options.overlay?(trajectoryIndex).flatMap {
                $0.values.count == frames[trajectoryIndex].count ? $0 : nil
            }
            let fieldColors = field.map(FieldColors.colors(for:))
            guard var bytes = renderer.renderBGRA(
                frameIndex: trajectoryIndex, camera: camera, colors: fieldColors,
                lines: lines(renderer: renderer, options: options,
                             trajectoryIndex: trajectoryIndex, overrideColors: fieldColors))
            else { return nil }
            if options.annotations {
                annotate(&bytes, width: w, height: h,
                         frame: trajectoryIndex + 1, of: frames.count,
                         angstromsPerPixel: angstromsPerPixel(renderer: renderer,
                                                              camera: camera, height: h),
                         legend: field.map(FieldColors.legend(for:)))
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
                                 options: Options,
                                 overlay: PerAtomField? = nil,
                                 bonds: BondSet? = nil) throws -> (width: Int, height: Int) {
        let w = options.width & ~1, h = options.height & ~1
        guard let renderer = OffscreenRenderer(frames: frames, width: w, height: h,
                                               pointSize: options.pointSize,
                                               background: options.background,
                                               style: options.style) else {
            throw NSError(domain: "MDRender", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the offscreen renderer (no Metal device, or empty trajectory)."])
        }
        let i = max(0, min(frames.count - 1, frameIndex))
        let field = (overlay ?? options.overlay?(i)).flatMap {
            $0.values.count == frames[i].count ? $0 : nil
        }
        let fieldColors = field.map(FieldColors.colors(for:))
        guard var bytes = renderer.renderBGRA(
            frameIndex: i, camera: options.camera, colors: fieldColors,
            lines: lines(renderer: renderer, options: options, trajectoryIndex: i,
                         overrideColors: fieldColors, bonds: bonds)) else {
            throw NSError(domain: "MDRender", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Render failed."])
        }
        if options.annotations {
            annotate(&bytes, width: w, height: h, frame: i + 1, of: frames.count,
                     angstromsPerPixel: angstromsPerPixel(renderer: renderer,
                                                          camera: options.camera, height: h),
                     legend: field.map(FieldColors.legend(for:)))
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

    // MARK: - Annotations (scale bar bottom-left, frame counter top-right,
    //         field legend bottom-right)

    private static func annotate(_ bytes: inout [UInt8], width: Int, height: Int,
                                 frame: Int, of total: Int, angstromsPerPixel: Double,
                                 legend: FieldColors.Legend? = nil) {
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

            if let legend {
                drawLegend(legend, in: ctx, width: CGFloat(width), s: s,
                           margin: margin, white: white)
            }
        }
    }

    // MARK: - Legend

    private static let legendMaxRows = 8

    /// Menlo is monospaced, so a character count is an exact width.
    private static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        CGFloat(text.count) * size * 0.62
    }

    private static func fit(_ text: String, size: CGFloat, into maxWidth: CGFloat) -> String {
        let maxChars = Int(maxWidth / (size * 0.62))
        guard maxChars >= 1, text.count > maxChars else { return text }
        return String(text.prefix(Swift.max(1, maxChars - 1))) + "…"
    }

    /// Bottom-right panel: title, then colour swatches or a sampled colour bar.
    /// Shares the scale bar's `s` scale and translucent black backing so the
    /// three annotations read as one set at 1080p and at GIF sizes.
    private static func drawLegend(_ legend: FieldColors.Legend, in ctx: CGContext,
                                   width: CGFloat, s: CGFloat, margin: CGFloat, white: CGColor) {
        let pad = 10 * s
        let titleSize = 20 * s
        let labelSize = 18 * s
        // Never let a long label reach across into the scale bar.
        let maxContent = Swift.max(60 * s, width * 0.40 - 2 * pad)
        let backing = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)

        func cg(_ c: SIMD3<Float>) -> CGColor {
            CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.95)
        }

        switch legend {
        case let .swatches(title, entries):
            let swatch = 16 * s
            let gap = 8 * s
            let rowH = 26 * s
            let shown = Swift.min(legendMaxRows, entries.count)
            var labels = entries.prefix(shown).map { $0.label }
            var colors = entries.prefix(shown).map { cg($0.color) }
            let overflow = entries.count > shown
            if overflow {
                labels.append("+\(entries.count - shown) more")
                colors.append(white)   // never drawn; keeps the arrays parallel
            }
            let labelBudget = maxContent - swatch - gap
            labels = labels.map { fit($0, size: labelSize, into: labelBudget) }
            let titleText = fit(title, size: titleSize, into: maxContent)
            let rows = labels.count
            let contentW = Swift.max(textWidth(titleText, size: titleSize),
                                     (labels.map { textWidth($0, size: labelSize) }.max() ?? 0)
                                        + swatch + gap)
            let panelW = contentW + 2 * pad
            let panelH = CGFloat(rows) * rowH + titleSize * 1.5 + 2 * pad
            let panelX = width - margin - panelW
            ctx.setFillColor(backing)
            ctx.fill(CGRect(x: panelX, y: margin, width: panelW, height: panelH))

            for (k, label) in labels.enumerated() {
                let y = margin + pad + rowH * CGFloat(rows - 1 - k)
                let isOverflowRow = overflow && k == rows - 1
                if !isOverflowRow {
                    ctx.setFillColor(colors[k])
                    ctx.fill(CGRect(x: panelX + pad, y: y + (rowH - swatch) / 2,
                                    width: swatch, height: swatch))
                }
                drawText(label, in: ctx,
                         at: CGPoint(x: panelX + pad + (isOverflowRow ? 0 : swatch + gap),
                                     y: y + rowH * 0.32),
                         size: labelSize, color: white)
            }
            drawText(titleText, in: ctx,
                     at: CGPoint(x: panelX + pad, y: margin + pad + rowH * CGFloat(rows) + titleSize * 0.3),
                     size: titleSize, color: white)

        case let .colorBar(title, lo, hi, colormapName):
            let barW = 18 * s
            let barH = 220 * s
            let minLabel = String(format: "%.3g", lo)
            let maxLabel = String(format: "%.3g", hi)
            let titleText = fit(title, size: titleSize, into: maxContent)
            let contentW = Swift.max(textWidth(titleText, size: titleSize),
                                     Swift.max(barW,
                                               Swift.max(textWidth(minLabel, size: labelSize),
                                                         textWidth(maxLabel, size: labelSize))))
            let panelW = contentW + 2 * pad
            let panelH = barH + labelSize * 1.4 * 2 + titleSize * 1.4 + 2 * pad
            let panelX = width - margin - panelW
            ctx.setFillColor(backing)
            ctx.fill(CGRect(x: panelX, y: margin, width: panelW, height: panelH))

            // Bar: t = 0 at the bottom (min) → 1 at the top (max).
            let barX = panelX + pad
            let barY = margin + pad + labelSize * 1.4
            let steps = 128
            let stepH = barH / CGFloat(steps)
            for k in 0..<steps {
                let t = Float(k) / Float(steps - 1)
                ctx.setFillColor(cg(FieldColors.sample(colormapName, at: t)))
                // Overlap by a hair so rounding never leaves a seam.
                ctx.fill(CGRect(x: barX, y: barY + stepH * CGFloat(k),
                                width: barW, height: stepH + 0.75))
            }
            drawText(minLabel, in: ctx,
                     at: CGPoint(x: barX, y: margin + pad + labelSize * 0.2),
                     size: labelSize, color: white)
            drawText(maxLabel, in: ctx,
                     at: CGPoint(x: barX, y: barY + barH + labelSize * 0.35),
                     size: labelSize, color: white)
            drawText(titleText, in: ctx,
                     at: CGPoint(x: panelX + pad, y: barY + barH + labelSize * 1.4 + titleSize * 0.3),
                     size: titleSize, color: white)
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
