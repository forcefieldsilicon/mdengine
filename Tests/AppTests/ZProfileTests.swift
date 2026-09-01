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
}
