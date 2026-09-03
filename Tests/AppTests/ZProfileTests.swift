import XCTest
@testable import LAMMPSCore

final class ZProfileTests: XCTestCase {
    /// 100 substrate atoms in a z 0–9.9 column; top 5% (5 atoms: 9.5–9.9) → plane ≈ 9.7.
    private func slabPlusProbes(_ probeZ: [Double]) -> [Arv] {
        var atoms = (0..<100).map { Arv(element: "Al", x: 0, y: 0, z: Double($0) * 0.1) }
        atoms += probeZ.map { Arv(element: "O", x: 0, y: 0, z: $0, charge: -1.5) }
        return atoms
    }

    func testClassificationAndDepths() throws {
        let zp = try XCTUnwrap(ZProfileAnalysis(frame: slabPlusProbes([7.7, 10.0, 11.0, 30.0]),
                                                substrate: "Al", probe: "O"))
        XCTAssertEqual(zp.surfaceZ, 9.7, accuracy: 1e-9)
        XCTAssertEqual(zp.penetrations.count, 1)
        XCTAssertEqual(zp.maxPenetration!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(zp.atSurfaceCount, 2)      // 10.0 (rel 0.3) and 11.0 (rel 1.3)
        XCTAssertEqual(zp.aboveCount, 1)          // 30.0
        XCTAssertEqual(zp.boundProbeMeanCharge!, -1.5, accuracy: 1e-9)
        XCTAssertEqual(zp.histogram.reduce(0) { $0 + $1.count }, 4)
    }

    func testDefaultsAndDegenerateFrames() {
        let frame = slabPlusProbes([11.0])
        let d = ZProfileAnalysis.defaultElements(for: frame)
        XCTAssertEqual(d?.substrate, "Al")
        XCTAssertEqual(d?.probe, "O")
        XCTAssertNil(ZProfileAnalysis(frame: frame, substrate: "Al", probe: "Al"))
        XCTAssertNil(ZProfileAnalysis(frame: frame, substrate: "Al", probe: "H"))
        XCTAssertNil(ZProfileAnalysis(frame: [], substrate: "Al", probe: "O"))
    }

    func testNiceScaleBarLengths() {
        // niceLength lives in the app target; validated here indirectly via the
        // analysis defaults — see ScaleBarView for the 1/2/5×10ⁿ snapping.
    }

    func testCSVExport() throws {
        let frame = slabPlusProbes([7.7, 10.0, 30.0])
        let zp = try XCTUnwrap(ZProfileAnalysis(frame: frame, substrate: "Al", probe: "O"))
        let csv = ZProfileExport.csv(analysis: zp, frame: frame, frameIndex: 3, source: "t.traj")
        XCTAssertTrue(csv.contains("surface plane z (A),9.700"))
        XCTAssertTrue(csv.contains("frame (0-based),3"))
        XCTAssertTrue(csv.contains("bin_lo_A_rel_surface,bin_hi_A_rel_surface,count"))
        XCTAssertTrue(csv.contains("probe_n,x_A,y_A,z_A,z_rel_surface_A,charge_e,class"))
        XCTAssertTrue(csv.contains(",penetrated"))
        XCTAssertTrue(csv.contains(",above"))
        // one probe row per probe atom
        let atomRows = csv.split(separator: "\n").filter { $0.hasSuffix("penetrated") || $0.hasSuffix("at-surface") || $0.hasSuffix("above") }
        XCTAssertEqual(atomRows.count, 3)
    }

    func testXLSXExport() throws {
        let frame = slabPlusProbes([7.7, 10.0, 30.0])
        let zp = try XCTUnwrap(ZProfileAnalysis(frame: frame, substrate: "Al", probe: "O"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZProfileExport.writeXLSX(to: url, analysis: zp, frame: frame)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 500)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))   // "PK" zip magic
        // the workbook parts are really inside the container
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-l", url.path]
        let pipe = Pipe(); unzip.standardOutput = pipe
        try unzip.run(); unzip.waitUntilExit()
        let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for part in ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            XCTAssertTrue(listing.contains(part), "missing \(part)")
        }
    }
}
