import XCTest
@testable import LAMMPSCore

final class CrystallinityToolTests: XCTestCase {

    /// Fraction of atoms carrying a given structure label, from the field.
    private func fraction(_ result: ToolResult, _ type: StructureType) -> Double {
        guard let values = result.field?.values, !values.isEmpty else { return 0 }
        return Double(values.filter { $0 == Float(type.rawValue) }.count) / Double(values.count)
    }

    private func summary(_ result: ToolResult, _ label: String) -> String? {
        result.summary.first { $0.label == label }?.value
    }

    private func run(_ frame: Frame, _ params: CrystallinityTool.Parameters = .init(),
                     context: AnalysisContext = AnalysisContext()) throws -> ToolResult {
        try CrystallinityTool.analyze(frame: frame, context: context, params: params)
    }

    // MARK: - Perfect lattices

    func testPerfectFCCIsAllFCC() throws {
        let r = try run(Fixtures.fcc(cells: 6))
        XCTAssertEqual(fraction(r, .fcc), 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.scalar!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary(r, "Crystalline fraction"), "100.0")
        XCTAssertEqual(summary(r, "Amorphicity index"), "0.0")
        XCTAssertEqual(r.field?.legendTitle, "Structure (a-CNA)")
        if case .categorical(let entries)? = r.field?.palette {
            XCTAssertEqual(entries.count, 5)
            XCTAssertEqual(entries[1].label, "FCC")
            XCTAssertEqual(entries[1].color, RGB(0.4, 1.0, 0.4))
        } else { XCTFail("categorical palette expected") }
        // Textbook q̄ for the perfect fcc environment (12 neighbours).
        XCTAssertEqual(Double(summary(r, "Mean q̄6")!)!, 0.5745, accuracy: 0.01)
        XCTAssertEqual(Double(summary(r, "Mean q̄4")!)!, 0.1909, accuracy: 0.01)
    }

    func testPerfectBCCIsAllBCC() throws {
        let r = try run(Fixtures.bcc(cells: 6))
        XCTAssertEqual(fraction(r, .bcc), 1.0, accuracy: 1e-9)
    }

    func testPerfectHCPIsAllHCP() throws {
        let r = try run(Fixtures.hcp(cells: 5))
        XCTAssertEqual(fraction(r, .hcp), 1.0, accuracy: 1e-9)
    }

    // MARK: - Disorder

    func testLiquidIsNeitherCrystallineNorOrdered() throws {
        let r = try run(Fixtures.liquid(cells: 5, sigma: 0.6))
        XCTAssertLessThan(r.scalar!, 0.10)
        XCTAssertLessThan(Double(summary(r, "Mean q̄6")!)!, 0.35)
        XCTAssertGreaterThan(Double(summary(r, "Amorphicity index")!)!, 90.0)
    }

    // MARK: - Open boundaries and fixed cutoff

    func testOpenSlabHasCrystallineInteriorAndAmorphousSurface() throws {
        let frame = Fixtures.fccSlabOpenBoundary(cells: 5)
        let r = try run(frame)
        XCTAssertEqual(r.field?.values[Fixtures.atom(frame)], Float(StructureType.fcc.rawValue))
        XCTAssertEqual(r.field?.values[Fixtures.atom(frame, furthest: true)],
                       Float(StructureType.other.rawValue))
        XCTAssertGreaterThan(fraction(r, .fcc), 0.1)
        XCTAssertLessThan(fraction(r, .fcc), 1.0)
        XCTAssertTrue(r.notes.contains { $0.contains("No box") })
    }

    func testFixedCutoffReproducesTheAdaptiveFCCResult() throws {
        // Between the first (2.86 Å) and second (4.05 Å) fcc shells.
        let r = try run(Fixtures.fcc(cells: 5), .init(cutoff: 3.45))
        XCTAssertEqual(fraction(r, .fcc), 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary(r, "Cutoff"), "3.450 Å (fixed)")
    }

    // MARK: - q̄6 method, profile, stride, cancellation

    func testQ6MethodPublishesAContinuousField() throws {
        let r = try run(Fixtures.fcc(cells: 5), .init(method: .q6))
        XCTAssertEqual(r.field?.legendTitle, "q̄6")
        XCTAssertEqual(r.scalar!, 1.0, accuracy: 1e-9)          // 0.575 > 0.5 everywhere
        XCTAssertEqual(Double(r.field!.values.first!), 0.5745, accuracy: 0.01)
        if case .continuous(let lo, let hi, let map)? = r.field?.palette {
            XCTAssertEqual(lo, 0); XCTAssertEqual(hi, 0.6); XCTAssertEqual(map, "viridis")
        } else { XCTFail("continuous palette expected") }

        let liquid = try run(Fixtures.liquid(cells: 4), .init(method: .q6))
        XCTAssertLessThan(liquid.scalar!, 0.10)
    }

    func testProfileAndStridedPreview() throws {
        let frame = Fixtures.fcc(cells: 5)
        let r = try run(frame)
        let profile = try XCTUnwrap(r.profile)
        XCTAssertEqual(profile.valueLabel, "crystalline fraction")
        // Every bin that holds atoms is fully crystalline; empty bins report 0.
        XCTAssertGreaterThan(profile.counts.filter { $0 > 0 }.count, 5)
        for (value, count) in zip(profile.values, profile.counts) where count > 0 {
            XCTAssertEqual(value, 1.0, accuracy: 1e-9)
        }

        let preview = try run(frame, .init(), context: AnalysisContext(stride: 4))
        XCTAssertEqual(preview.scalar!, 1.0, accuracy: 1e-9)     // fractions use the sample
        XCTAssertEqual(fraction(preview, .fcc), 0.25, accuracy: 1e-9)
        XCTAssertTrue(preview.notes.contains { $0.contains("every 4th atom") })
    }

    func testCancellationStopsEarly() {
        XCTAssertThrowsError(try run(Fixtures.fcc(cells: 5), .init(),
                                     context: AnalysisContext(isCancelled: { true }))) {
            XCTAssertEqual($0 as? AnalysisError, .cancelled)
        }
    }

    func testRegistersAndRoundTripsParameters() throws {
        let meta = ToolMetadata(id: CrystallinityTool.id, title: CrystallinityTool.title,
                                category: CrystallinityTool.category,
                                functions: CrystallinityTool.functions.sorted { $0.rawValue < $1.rawValue },
                                requirements: [], supportsStridedPreview: true)
        XCTAssertEqual(meta.category, .structureOrder)
        XCTAssertTrue(CrystallinityTool.requirements.isEmpty)

        let erased = AnyAnalysisTool(CrystallinityTool.self)
        let json = try JSONEncoder().encode(CrystallinityTool.Parameters(method: .q6, bins: 8))
        let r = try erased.analyze(frame: Fixtures.fcc(cells: 4), context: AnalysisContext(),
                                   parametersJSON: json)
        XCTAssertEqual(r.field?.legendTitle, "q̄6")
        XCTAssertGreaterThan(erased.estimatedCost(atoms: 1000, parametersJSON: json), 3000)
    }
}
