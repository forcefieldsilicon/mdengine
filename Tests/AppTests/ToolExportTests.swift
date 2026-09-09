import XCTest
@testable import LAMMPSCore

/// One exporter for every tool result: CSV layout kept from the tool cards, .xlsx via `Zip`.
final class ToolExportTests: XCTestCase {
    private func sampleResult() -> ToolResult {
        let field = PerAtomField(name: "class", values: [0, 1, 1, 2],
                                 palette: .categorical([("none", RGB(0.5, 0.5, 0.5)), ("contact A", RGB(1, 0.5, 0)), ("H-bond", RGB(0, 1, 0))]),
                                 legendTitle: "Interaction")
        let profile = Profile(axisLabel: "z − surface (Å)", valueLabel: "probe atoms",
                              edges: [-2, -1, 0, 1], values: [1, 0, 2], counts: [1, 0, 2])
        return ToolResult(summary: [SummaryRow("Surface plane z", "9.700", unit: "Å"),
                                    SummaryRow("Substrate / probe", "Al / O"),
                                    SummaryRow("Penetrated, \"quoted\"", "1")],
                          field: field, profile: profile, scalar: 2.0,
                          notes: ["Preview: 1/4 of atoms."])
    }

    func testCSVLayout() {
        let csv = ToolExport.csv(sampleResult(),
                                 provenance: .init(toolTitle: "Z-profile", toolId: "z_profile", source: "t.xyz", frameIndex: 3),
                                 series: [0: 1.5, 2: 2.5])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "# MDEngine Z-profile — t.xyz frame 3")
        XCTAssertEqual(lines[1], "section,label,value,unit")
        XCTAssertTrue(lines.contains("summary,Surface plane z,9.700,Å"))
        XCTAssertTrue(lines.contains("summary,\"Penetrated, \"\"quoted\"\"\",1,"))
        XCTAssertTrue(lines.contains("profile,z − surface (Å) centre,probe atoms,count"))
        XCTAssertTrue(lines.contains("profile,-1.5,1.0,1"))
        XCTAssertTrue(lines.contains("series,0,1.5,"))
        XCTAssertTrue(lines.contains("series,2,2.5,"))
        XCTAssertEqual(lines.last, "# Preview: 1/4 of atoms.")
    }

    func testXLSXHasOneSheetPerSection() throws {
        let prov = ToolExport.Provenance(toolTitle: "Adhesion", toolId: "adhesion", source: "t.xyz", frameIndex: 0)
        let data = try ToolExport.xlsx(sampleResult(), provenance: prov, series: [1: 3.0])
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
        let names = try Zip.entryNames(data)
        XCTAssertEqual(names.first, "[Content_Types].xml")
        for part in ["_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                     "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml",
                     "xl/worksheets/sheet3.xml", "xl/worksheets/sheet4.xml"] {
            XCTAssertTrue(names.contains(part), "missing \(part)")
        }
        XCTAssertFalse(names.contains("xl/worksheets/sheet5.xml"))

        // The reference reader accepts the container.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("te-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tqq", url.path]
        unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)

        // Sheet names and the categorical labels made it into the XML.
        let wb = ToolExport.workbookParts([("Summary", []), ("Profile", []), ("Series", []), ("Field", [])])
        let workbookXML = String(decoding: wb[2].data, as: UTF8.self)
        for n in ["Summary", "Profile", "Series", "Field"] { XCTAssertTrue(workbookXML.contains("name=\"\(n)\"")) }
        let fieldRows = ToolExport.sheetXML([ToolExport.sCell("atom (0-based)")])
        XCTAssertTrue(fieldRows.contains("<row r=\"1\">"))
    }

    func testFieldSheetIsCappedAndXMLEscaped() throws {
        var r = sampleResult()
        r = ToolResult(summary: [SummaryRow("a < b & c", "x")], field: PerAtomField(name: "v", values: [Float](repeating: 1, count: ToolExport.fieldSheetMaxAtoms + 1), palette: .continuous(min: 0, max: 1, colormapName: "viridis"), legendTitle: "v"), profile: nil, scalar: nil, notes: [])
        let data = try ToolExport.xlsx(r, provenance: .init(toolTitle: "T", toolId: "t"))
        let names = try Zip.entryNames(data)
        XCTAssertEqual(names.filter { $0.hasPrefix("xl/worksheets/") }.count, 1, "field above the cap must not become a sheet")
        XCTAssertEqual(ToolExport.xml("a < b & c"), "a &lt; b &amp; c")
        XCTAssertEqual(ToolExport.sheetName("Bad:/Name?*[x]", 0), "BadNamex")
        XCTAssertEqual(ToolExport.sheetName(String(repeating: "s", count: 40), 0).count, 31)
    }
}
