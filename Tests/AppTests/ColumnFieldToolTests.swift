import XCTest
@testable import LAMMPSCore

final class ColumnFieldToolTests: XCTestCase {
    private func frame() -> Frame {
        let atoms = (0..<10).map { Arv(element: "Al", x: 0, y: 0, z: Double($0), charge: Double($0) * 0.1) }
        return Frame(atoms: atoms, columns: ["c_pe": (0..<10).map { Float($0) * -2 }])
    }

    func testColumnsAndZDefault() throws {
        let f = frame()
        XCTAssertEqual(ColumnFieldTool.availableColumns(f), ["x", "y", "z", "charge", "c_pe"])
        let r = try ColumnFieldTool.analyze(frame: f, context: AnalysisContext(), params: .init())
        XCTAssertEqual(r.field?.values.count, 10)
        XCTAssertEqual(r.scalar!, 4.5, accuracy: 1e-9)
        if case .continuous(let lo, let hi, let name)? = r.field?.palette {
            XCTAssertEqual(lo, 0); XCTAssertEqual(hi, 9); XCTAssertEqual(name, "viridis")
        } else { XCTFail("continuous palette expected") }
        XCTAssertGreaterThan(r.profile?.values.count ?? 0, 0)   // Binning widens bins to ≥ 0.5 Å
    }

    func testDataColumnAndFixedRange() throws {
        let p = ColumnFieldTool.Parameters(column: "c_pe", colormap: "inferno", rangeMin: -20, rangeMax: 0)
        let r = try ColumnFieldTool.analyze(frame: frame(), context: AnalysisContext(), params: p)
        XCTAssertEqual(r.field?.values.first, 0)
        XCTAssertEqual(r.field?.values.last, -18)
        if case .continuous(let lo, let hi, _)? = r.field?.palette { XCTAssertEqual(lo, -20); XCTAssertEqual(hi, 0) }
        XCTAssertThrowsError(try ColumnFieldTool.analyze(frame: frame(), context: AnalysisContext(),
                                                         params: .init(column: "nope")))
    }

    func testRegistryRoundTripThroughJSON() throws {
        let reg = ToolRegistry(); reg.registerBuiltIns()
        XCTAssertTrue(reg.metadata.contains { $0.id == "column_field" && $0.category == .renderingExport })
        let json = try JSONEncoder().encode(ColumnFieldTool.Parameters(column: "charge"))
        let r = try reg.tool("column_field")!.analyze(frame: frame(), context: AnalysisContext(), parametersJSON: json)
        XCTAssertEqual(r.summary.first?.value, "charge")
    }
}
