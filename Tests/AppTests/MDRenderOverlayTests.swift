//
//  MDRenderOverlayTests.swift — per-atom colour override + baked legend
//  (GJOB-135, phase 0c). Metal-backed: skipped where there is no GPU.
//

import XCTest
import Metal
import CoreGraphics
import ImageIO
import simd
@testable import LAMMPSCore
@testable import MDRender

final class MDRenderOverlayTests: XCTestCase {

    private func requireMetal() throws {
        if MTLCreateSystemDefaultDevice() == nil {
            throw XCTSkip("No Metal device on this machine.")
        }
    }

    /// Big sprites: at 64 px tall the default point size is sub-pixel.
    private func renderer(_ frames: [[Arv]], _ n: Int = 64) -> OffscreenRenderer? {
        OffscreenRenderer(frames: frames, width: n, height: n, pointSize: 200)
    }

    private func centrePixel(_ bytes: [UInt8], _ n: Int) -> (r: Int, g: Int, b: Int) {
        let o = ((n / 2) * n + n / 2) * 4          // BGRA
        return (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
    }

    // MARK: - (a) colour override reaches the pixels

    func testColorOverrideRecolorsAtom() throws {
        try requireMetal()
        // "N" is CPK blue — a colour no red override could be confused with.
        let frames = [[Arv(element: "N", x: 0, y: 0, z: 0)]]
        guard let r = renderer(frames) else { return XCTFail("no renderer") }

        let plain = try XCTUnwrap(r.renderBGRA(frameIndex: 0, camera: .init()))
        let p = centrePixel(plain, 64)
        XCTAssertGreaterThan(p.b, p.r + 40, "element colour should be blue-dominant")

        let red = try XCTUnwrap(r.renderBGRA(frameIndex: 0, camera: .init(),
                                             colors: [SIMD3<Float>(1, 0, 0)]))
        let q = centrePixel(red, 64)
        XCTAssertGreaterThan(q.r, 200)
        XCTAssertGreaterThan(q.r, q.b + 100, "override should be red-dominant")
    }

    // MARK: - (b) a wrong-length override is ignored, not misattributed

    func testCountMismatchOverrideIsIgnored() throws {
        try requireMetal()
        let frames = [[Arv(element: "N", x: 0, y: 0, z: 0)]]
        guard let r = renderer(frames) else { return XCTFail("no renderer") }
        let plain = try XCTUnwrap(r.renderBGRA(frameIndex: 0, camera: .init()))
        let mismatched = try XCTUnwrap(r.renderBGRA(
            frameIndex: 0, camera: .init(),
            colors: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]))
        XCTAssertEqual(plain, mismatched, "2 colours for 1 atom must render unchanged")

        let empty = try XCTUnwrap(r.renderBGRA(frameIndex: 0, camera: .init(), colors: []))
        XCTAssertEqual(plain, empty)
    }

    // MARK: - (c) exportPNG bakes a legend into the bottom-right

    func testExportPNGWithContinuousOverlayDrawsLegend() throws {
        try requireMetal()
        var atoms: [Arv] = []
        for i in 0..<40 {
            let t = Double(i)
            atoms.append(Arv(element: "Al", x: cos(t) * 5, y: sin(t) * 5, z: t * 0.2))
        }
        let field = PerAtomField(name: "charge",
                                 values: (0..<atoms.count).map { Float($0) / 39 },
                                 palette: .continuous(min: 0, max: 1, colormapName: "viridis"),
                                 legendTitle: "charge (e)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrender-overlay-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let options = VideoExporter.Options(width: 480, height: 360, annotations: true,
                                            pointSize: 24)
        let size = try VideoExporter.exportPNG(frames: [atoms], frameIndex: 0, to: url,
                                               options: options, overlay: field)
        XCTAssertEqual(size.width, 480)
        let bytes = try Data(contentsOf: url).count
        XCTAssertGreaterThan(bytes, 1024, "PNG should be more than 1 KB")

        let px = try XCTUnwrap(rgbaPixels(of: url), "could not read the PNG back")
        // Bottom-right strip: beyond the atoms, inside the legend panel.
        var lit = 0
        for row in (360 - 100)..<(360 - 12) {
            for col in (480 - 60)..<(480 - 4) {
                let o = (row * 480 + col) * 4
                let d = max(abs(Int(px[o]) - 13), max(abs(Int(px[o + 1]) - 13),
                                                      abs(Int(px[o + 2]) - 20)))
                if d > 30 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 100, "legend pixels expected in the bottom-right")

        // Control: without the overlay that same region stays background.
        let plainURL = url.deletingLastPathComponent()
            .appendingPathComponent("mdrender-plain-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: plainURL) }
        _ = try VideoExporter.exportPNG(frames: [atoms], frameIndex: 0, to: plainURL,
                                        options: options)
        let plain = try XCTUnwrap(rgbaPixels(of: plainURL))
        var plainLit = 0
        for row in (360 - 100)..<(360 - 12) {
            for col in (480 - 60)..<(480 - 4) {
                let o = (row * 480 + col) * 4
                let d = max(abs(Int(plain[o]) - 13), max(abs(Int(plain[o + 1]) - 13),
                                                         abs(Int(plain[o + 2]) - 20)))
                if d > 30 { plainLit += 1 }
            }
        }
        XCTAssertEqual(plainLit, 0, "no overlay must leave the bottom-right untouched")
    }

    /// Options.overlay drives export the same way, and a wrong-length field is dropped.
    func testOptionsOverlayClosureAndMismatchAreSafe() throws {
        try requireMetal()
        let atoms = (0..<12).map { Arv(element: "Al", x: Double($0), y: 0, z: 0) }
        let bad = PerAtomField(name: "x", values: [0, 1, 2],
                               palette: .continuous(min: 0, max: 2, colormapName: "viridis"),
                               legendTitle: "x")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrender-mismatch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let options = VideoExporter.Options(width: 320, height: 240,
                                            overlay: { _ in bad })
        XCTAssertNoThrow(try VideoExporter.exportPNG(frames: [atoms], frameIndex: 0,
                                                     to: url, options: options))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - (d) legend model round trip

    func testLegendRoundTrip() throws {
        let categorical = PerAtomField(
            name: "phase", values: [0, 1, 0, 2],
            palette: .categorical([("bulk", RGB(1, 0, 0)), ("surface", RGB(0, 1, 0)),
                                   ("oxide", RGB(0, 0, 1))]),
            legendTitle: "phase")
        guard case let .swatches(title, entries) = FieldColors.legend(for: categorical) else {
            return XCTFail("categorical field should give swatches")
        }
        XCTAssertEqual(title, "phase")
        XCTAssertEqual(entries.map { $0.label }, ["bulk", "surface", "oxide"])
        XCTAssertEqual(entries[1].color, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(FieldColors.colors(for: categorical)[3], SIMD3<Float>(0, 0, 1))

        let continuous = PerAtomField(
            name: "q", values: [-1, 0, 1],
            palette: .continuous(min: -1, max: 1, colormapName: "coolwarm"),
            legendTitle: "charge (e)")
        guard case let .colorBar(t2, lo, hi, map) = FieldColors.legend(for: continuous) else {
            return XCTFail("continuous field should give a colour bar")
        }
        XCTAssertEqual(t2, "charge (e)")
        XCTAssertEqual(lo, -1)
        XCTAssertEqual(hi, 1)
        XCTAssertEqual(map, "coolwarm")
        XCTAssertEqual(FieldColors.colors(for: continuous)[0], FieldColors.sample("coolwarm", at: 0))
        XCTAssertEqual(FieldColors.colors(for: continuous)[2], FieldColors.sample("coolwarm", at: 1))
    }

    // MARK: - helpers

    /// Decode a PNG to tightly packed RGBA bytes, row 0 = top.
    private func rgbaPixels(of url: URL) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        return ok ? buf : nil
    }
}
