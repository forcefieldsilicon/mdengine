import Foundation

/// Tabular export of a `ZProfileAnalysis`: CSV, or a minimal two-sheet
/// .xlsx (Z-profile summary + histogram on sheet 1, per-probe-atom rows on
/// sheet 2). The .xlsx is hand-assembled Office Open XML — inline strings,
/// no shared-strings table — and zipped with the system `zip`, so there are
/// no dependencies.
public enum ZProfileExport {

    /// One row per probe atom of `frame`, classified against the analysis.
    public struct ProbeRow {
        public let index: Int          // position among probe atoms (Arv has no id)
        public let x, y, z: Double
        public let zRelSurface: Double // negative = below the surface plane
        public let charge: Double?
        public let classification: String
    }

    public static func probeRows(analysis zp: ZProfileAnalysis, frame: [Arv]) -> [ProbeRow] {
        frame.filter { $0.element == zp.probeElement }.enumerated().map { i, a in
            let rel = a.z - zp.surfaceZ
            let cls = rel < 0 ? "penetrated"
                : rel < ZProfileAnalysis.surfaceBand ? "at-surface" : "above"
            return ProbeRow(index: i + 1, x: a.x, y: a.y, z: a.z,
                            zRelSurface: rel, charge: a.charge, classification: cls)
        }
    }

    private static func summary(_ zp: ZProfileAnalysis, frameIndex: Int?,
                                source: String?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let source { rows.append(("source", source)) }
        if let frameIndex { rows.append(("frame (0-based)", "\(frameIndex)")) }
        rows.append(contentsOf: [
            ("substrate", zp.substrateElement),
            ("probe", zp.probeElement),
            ("surface plane z (A)", String(format: "%.3f", zp.surfaceZ)),
            ("substrate max z (A)", String(format: "%.3f", zp.substrateMaxZ)),
            ("penetrated", "\(zp.penetrations.count)"),
            ("at surface (<\(String(format: "%.1f", ZProfileAnalysis.surfaceBand)) A)",
             "\(zp.atSurfaceCount)"),
            ("above / in flight", "\(zp.aboveCount)"),
        ])
        if let d = zp.minPenetration { rows.append(("min penetration (A)", String(format: "%.3f", d))) }
        if let d = zp.meanPenetration { rows.append(("mean penetration (A)", String(format: "%.3f", d))) }
        if let d = zp.maxPenetration { rows.append(("max penetration (A)", String(format: "%.3f", d))) }
        if let q = zp.boundProbeMeanCharge {
            rows.append(("bound probe mean charge (e)", String(format: "%+.3f", q)))
        }
        return rows
    }

    // MARK: - CSV

    /// Sectioned CSV: summary, histogram (depth axis relative to the surface
    /// plane, negative = penetrated), then one row per probe atom.
    public static func csv(analysis zp: ZProfileAnalysis, frame: [Arv],
                           frameIndex: Int? = nil, source: String? = nil) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { ",\"\n".contains($0) })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "# MDEngine Z-profile\n"
        for (k, v) in summary(zp, frameIndex: frameIndex, source: source) {
            out += "\(esc(k)),\(esc(v))\n"
        }
        out += "\nbin_lo_A_rel_surface,bin_hi_A_rel_surface,count\n"
        for bin in zp.histogram {
            out += String(format: "%.3f,%.3f,%d\n",
                          bin.range.lowerBound, bin.range.upperBound, bin.count)
        }
        out += "\nprobe_n,x_A,y_A,z_A,z_rel_surface_A,charge_e,class\n"
        for r in probeRows(analysis: zp, frame: frame) {
            let q = r.charge.map { String(format: "%.4f", $0) } ?? ""
            out += String(format: "%d,%.4f,%.4f,%.4f,%.4f,%@,%@\n",
                          r.index, r.x, r.y, r.z, r.zRelSurface, q, r.classification)
        }
        return out
    }

    // MARK: - XLSX

    /// Writes a two-sheet workbook. Throws if the system `zip` is missing or fails.
    public static func writeXLSX(to url: URL, analysis zp: ZProfileAnalysis, frame: [Arv],
                                 frameIndex: Int? = nil, source: String? = nil) throws {
        func xml(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        func sCell(_ s: String) -> String { "<c t=\"inlineStr\"><is><t>\(xml(s))</t></is></c>" }
        func nCell(_ v: Double, _ fmt: String = "%.4f") -> String { "<c><v>\(String(format: fmt, v))</v></c>" }
        func nCell(_ v: Int) -> String { "<c><v>\(v)</v></c>" }
        func sheet(_ rows: [String]) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            + rows.map { "<row>\($0)</row>" }.joined()
            + "</sheetData></worksheet>"
        }

        var s1: [String] = [sCell("MDEngine Z-profile") + sCell("")]
        for (k, v) in summary(zp, frameIndex: frameIndex, source: source) {
            s1.append(sCell(k) + sCell(v))
        }
        s1.append(sCell("") )
        s1.append(sCell("bin lo (A rel surface)") + sCell("bin hi (A rel surface)") + sCell("count"))
        for bin in zp.histogram {
            s1.append(nCell(bin.range.lowerBound, "%.3f") + nCell(bin.range.upperBound, "%.3f") + nCell(bin.count))
        }

        var s2: [String] = [sCell("probe n") + sCell("x (A)") + sCell("y (A)") + sCell("z (A)")
                            + sCell("z rel surface (A)") + sCell("charge (e)") + sCell("class")]
        for r in probeRows(analysis: zp, frame: frame) {
            s2.append(nCell(r.index) + nCell(r.x) + nCell(r.y) + nCell(r.z) + nCell(r.zRelSurface)
                      + (r.charge.map { nCell($0) } ?? sCell(""))
                      + sCell(r.classification))
        }

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Z-profile" sheetId="1" r:id="rId1"/><sheet name="Atoms" sheetId="2" r:id="rId2"/></sheets>
        </workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        </Relationships>
        """

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mdengine-xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        try contentTypes.write(to: work.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: work.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try workbook.write(to: work.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try workbookRels.write(to: work.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try sheet(s1).write(to: work.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        try sheet(s2).write(to: work.appendingPathComponent("xl/worksheets/sheet2.xml"), atomically: true, encoding: .utf8)

        let staging = work.appendingPathComponent("out.xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-r", "-X", "-q", staging.path,
                         "[Content_Types].xml", "_rels", "xl"]
        zip.currentDirectoryURL = work
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "ZProfileExport", code: Int(zip.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip failed (status \(zip.terminationStatus))"])
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: staging, to: url)
    }
}
