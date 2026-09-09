//
//  ToolExport.swift — CSV and .xlsx for ANY tool result.
//
//  One exporter for the whole registry (design §1 "Export (CSV/XLSX, same writer as
//  z-profile)"): the summary table, the binned profile, the time series over frames and,
//  in the workbook, the per-atom field. Replaces the z-profile-only ZProfileExport; the
//  .xlsx is hand-assembled Office Open XML (inline strings, no shared-strings table) in a
//  container written by `Zip` — no /usr/bin/zip, so it works in a sandbox and on iOS.
//

import Foundation

public enum ToolExport {

    /// Where the numbers came from — the header of the CSV and the first rows of the workbook.
    public struct Provenance {
        public var toolTitle: String
        public var toolId: String
        public var source: String?       // trajectory file name
        public var frameIndex: Int?      // 0-based frame the result belongs to
        public init(toolTitle: String, toolId: String, source: String? = nil, frameIndex: Int? = nil) {
            self.toolTitle = toolTitle
            self.toolId = toolId
            self.source = source
            self.frameIndex = frameIndex
        }
    }

    /// Per-atom values above this go to a note instead of a sheet (Excel's own row cap is
    /// 1 048 576, and a 100 k-row inline-string sheet is already ~8 MB of XML).
    public static let fieldSheetMaxAtoms = 100_000

    // MARK: - CSV (unchanged layout from the tool cards: section,label,value,unit)

    public static func csv(_ result: ToolResult, provenance p: Provenance,
                           series: [Int: Double] = [:]) -> String {
        var lines = ["# MDEngine \(p.toolTitle) — \(p.source ?? "trajectory") frame \(p.frameIndex.map(String.init) ?? "?")",
                     "section,label,value,unit"]
        for row in result.summary {
            lines.append("summary,\(q(row.label)),\(q(row.value)),\(q(row.unit ?? ""))")
        }
        if let pr = result.profile {
            lines.append("")
            lines.append("profile,\(q(pr.axisLabel)) centre,\(q(pr.valueLabel)),count")
            for (n, c) in pr.centers.enumerated() {
                lines.append("profile,\(c),\(pr.values[n]),\(pr.counts[n])")
            }
        }
        if !series.isEmpty {
            lines.append("")
            lines.append("series,frame,scalar,")
            for k in series.keys.sorted() { lines.append("series,\(k),\(series[k]!),") }
        }
        for note in result.notes { lines.append("# \(note)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func q(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    // MARK: - XLSX

    /// Sheets: Summary (provenance, table, notes), then Profile / Series / Field when present.
    public static func xlsx(_ result: ToolResult, provenance p: Provenance,
                            series: [Int: Double] = [:], includeField: Bool = true) throws -> Data {
        var sheets: [(name: String, rows: [String])] = []

        // Summary
        var s1: [String] = [sCell("MDEngine \(p.toolTitle)") + sCell("")]
        s1.append(sCell("tool") + sCell(p.toolId))
        if let src = p.source { s1.append(sCell("source") + sCell(src)) }
        if let fi = p.frameIndex { s1.append(sCell("frame (0-based)") + nCell(fi)) }
        s1.append(sCell(""))
        s1.append(sCell("label") + sCell("value") + sCell("unit"))
        for row in result.summary {
            s1.append(sCell(row.label) + cell(row.value) + sCell(row.unit ?? ""))
        }
        if let f = result.field, !includeField || f.values.count > fieldSheetMaxAtoms {
            s1.append(sCell(""))
            s1.append(sCell("per-atom field “\(f.name)”: \(f.values.count) values — not written "
                            + (includeField ? "(above \(fieldSheetMaxAtoms) atoms); use CSV export or the MCP analyze tool with include_field" : "(field excluded)")))
        }
        if !result.notes.isEmpty {
            s1.append(sCell(""))
            s1.append(sCell("notes"))
            for n in result.notes { s1.append(sCell(n)) }
        }
        sheets.append(("Summary", s1))

        // Profile
        if let pr = result.profile {
            var rows: [String] = [sCell("\(pr.axisLabel) lo") + sCell("\(pr.axisLabel) hi") + sCell("centre")
                                  + sCell(pr.valueLabel) + sCell("count")]
            let centers = pr.centers
            for n in centers.indices {
                rows.append(nCell(pr.edges[n]) + nCell(pr.edges[n + 1]) + nCell(centers[n])
                            + nCell(pr.values[n]) + nCell(pr.counts[n]))
            }
            sheets.append(("Profile", rows))
        }

        // Series
        if !series.isEmpty {
            var rows: [String] = [sCell("frame") + sCell("scalar")]
            for k in series.keys.sorted() { rows.append(nCell(k) + nCell(series[k]!)) }
            sheets.append(("Series", rows))
        }

        // Field (per atom)
        if includeField, let f = result.field, f.values.count <= fieldSheetMaxAtoms {
            var labels: [String]? = nil
            if case .categorical(let entries) = f.palette { labels = entries.map { $0.label } }
            var rows: [String] = [sCell("atom (0-based)") + sCell(f.name) + (labels == nil ? "" : sCell("label"))]
            for (i, v) in f.values.enumerated() {
                var r = nCell(i) + nCell(Double(v))
                if let labels {
                    let k = Int(v.rounded())
                    r += sCell(labels.indices.contains(k) ? labels[k] : "")
                }
                rows.append(r)
            }
            sheets.append(("Field", rows))
        }

        return try Zip.archive(workbookParts(sheets))
    }

    public static func writeXLSX(_ result: ToolResult, provenance p: Provenance, to url: URL,
                                 series: [Int: Double] = [:], includeField: Bool = true) throws {
        try xlsx(result, provenance: p, series: series, includeField: includeField).write(to: url, options: .atomic)
    }

    // MARK: - Office Open XML assembly

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func sCell(_ s: String) -> String { "<c t=\"inlineStr\"><is><t>\(xml(s))</t></is></c>" }
    static func nCell(_ v: Double) -> String {
        guard v.isFinite else { return sCell(v.isNaN ? "NaN" : (v > 0 ? "inf" : "-inf")) }
        return "<c><v>\(v)</v></c>"
    }
    static func nCell(_ v: Int) -> String { "<c><v>\(v)</v></c>" }
    /// A summary value that parses as a number becomes a numeric cell, so spreadsheets can compute on it.
    static func cell(_ s: String) -> String {
        if let d = Double(s.replacingOccurrences(of: ",", with: "")), d.isFinite { return nCell(d) }
        return sCell(s)
    }

    static func sheetXML(_ rows: [String]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        + rows.enumerated().map { "<row r=\"\($0.offset + 1)\">\($0.element)</row>" }.joined()
        + "</sheetData></worksheet>"
    }

    static func workbookParts(_ sheets: [(name: String, rows: [String])]) -> [Zip.Entry] {
        let overrides = sheets.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + overrides + "</Types>"
        let rootRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>"
        let sheetTags = sheets.enumerated().map {
            "<sheet name=\"\(xml(sheetName($0.element.name, $0.offset)))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>"
        }.joined()
        let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<sheets>\(sheetTags)</sheets></workbook>"
        let wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + sheets.indices.map {
                "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
              }.joined()
            + "</Relationships>"

        var parts: [Zip.Entry] = [
            Zip.Entry(path: "[Content_Types].xml", text: contentTypes),
            Zip.Entry(path: "_rels/.rels", text: rootRels),
            Zip.Entry(path: "xl/workbook.xml", text: workbook),
            Zip.Entry(path: "xl/_rels/workbook.xml.rels", text: wbRels),
        ]
        for (i, s) in sheets.enumerated() {
            parts.append(Zip.Entry(path: "xl/worksheets/sheet\(i + 1).xml", text: sheetXML(s.rows)))
        }
        return parts
    }

    /// Excel limits: 31 chars, none of : \ / ? * [ ] — and unique.
    static func sheetName(_ raw: String, _ index: Int) -> String {
        var s = raw.filter { !":\\/?*[]".contains($0) }
        if s.isEmpty { s = "Sheet\(index + 1)" }
        return String(s.prefix(31))
    }
}
