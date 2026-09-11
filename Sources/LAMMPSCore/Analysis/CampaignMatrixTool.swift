//
//  CampaignMatrixTool.swift — read a screening campaign's matrix back into the inspector.
//
//  The sibling of FEPResultsTool: the computation happened on a GPU somewhere
//  else, and this tool's job is to show what came back and to be honest about
//  what it does not support. Coverage and resolution first (they qualify every
//  number under them), then the grid, then the selectivity ratios, then the
//  compromises.
//
//  The "frame" axis is the CELL INDEX of one receptor column, not time: `scalar`
//  is the value of the cell at `context.frameIndex` in the current sort, so
//  scrubbing walks a column ligand by ligand.
//
//  Two rules this tool exists to keep:
//
//  * An undelivered cell is ABSENT, never zero. Most cells in a live campaign
//    have no number because prep is the bottleneck, and a `0` in a force column
//    would read as "no adhesion" — the opposite of "not measured yet". The
//    column walked by the frame axis contains delivered cells only, and the
//    unprepared ones are counted in the summary and the notes instead.
//  * The tool never decides which direction is stronger, what the unit is, or
//    how a tier was formed. `direction`, `label`, `unit` and the per-column
//    order all come out of matrix.json, because the producer (campaign.py)
//    already knows and two copies of that knowledge would drift.
//

import Foundation

public struct CampaignMatrixTool: AnalysisTool {
    public static let id = "campaign_matrix"
    public static let title = "Campaign matrix (tiers)"
    public static let category = ToolCategory.adhesionBinding
    public static let functions: Set<ToolFunction> = [.scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.sideFile]
    /// A JSON read and some sorting — nothing scales with atom count.
    public static let supportsStridedPreview = false

    public enum SortBy: String, Codable, CaseIterable {
        /// The producer's own strongest-first order, which the tier letters follow.
        case tier
        /// Strongest value first, honouring the file's `direction`.
        case value
        /// Widest band first — the re-run queue.
        case band
    }

    public struct Parameters: Codable, Equatable {
        /// Explicit `matrix.json`; nil = look next to `context.sourceURL`.
        public var jsonPath: String?
        /// Which receptor column the frame axis walks; nil = the primary receptor.
        public var receptor: String?
        public var sortBy: SortBy
        public init(jsonPath: String? = nil, receptor: String? = nil, sortBy: SortBy = .tier) {
            self.jsonPath = jsonPath
            self.receptor = receptor
            self.sortBy = sortBy
        }
    }

    public static let defaultParameters = Parameters()
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 40 }

    // MARK: - Resolution

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Quoted to the user when the throw is `.missingRequirement(.sideFile)`,
    /// which carries no message of its own.
    public static func searchNote(context: AnalysisContext, params: Parameters) -> String {
        if let p = params.jsonPath { return "Looked for the campaign matrix at \(expand(p).path)." }
        guard let src = context.sourceURL else {
            return "No file path is known, so there is nowhere to look for matrix.json — set jsonPath."
        }
        return "No matrix.json found. Looked in: "
            + CampaignMatrix.searchLocations(near: src).map { $0.path }.joined(separator: ", ")
            + ". Write one with `campaign.py matrix <campaign>`."
    }

    static func resolveJSON(context: AnalysisContext, params: Parameters) -> URL? {
        if let p = params.jsonPath {
            let u = expand(p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard let src = context.sourceURL else { return nil }
        return CampaignMatrix.locate(near: src)
    }

    /// Cell order for both the table and the `scalar` axis. Delivered cells only —
    /// an unprepared cell has nothing to plot and must not become a zero.
    static func sorted(_ m: CampaignMatrix, receptor: String, by key: SortBy) -> [CampaignMatrix.Cell] {
        let col = m.column(receptor)                      // producer order, tier letters agree with it
        switch key {
        case .tier:
            return col
        case .value:
            return col.sorted { a, b in
                guard let x = a.value, let y = b.value else { return b.value == nil }
                return m.lowerIsStronger ? x < y : x > y
            }
        case .band:
            return col.sorted { ($0.uncertainty ?? -1) > ($1.uncertainty ?? -1) }
        }
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let url = resolveJSON(context: context, params: params),
              let m = try? CampaignMatrix.load(url)
        else { throw AnalysisError.missingRequirement(.sideFile) }
        guard !m.cells.isEmpty else {
            throw AnalysisError.notApplicable("\(url.lastPathComponent) has no cells — the campaign has not been initialised yet.")
        }
        guard let receptor = params.receptor ?? m.primaryColumn else {
            throw AnalysisError.notApplicable("\(url.lastPathComponent) names no receptors.")
        }

        let unit = m.displayUnit
        let cells = sorted(m, receptor: receptor, by: params.sortBy)
        let pending = m.undelivered()

        var rows: [SummaryRow] = [
            SummaryRow("Campaign", (m.campaign ?? url.deletingLastPathComponent().lastPathComponent)
                       + (m.protocolName.map { " · \($0)" } ?? "")),
            SummaryRow("Quantity", (m.label ?? m.quantity ?? "—")
                       + " · stronger = \(m.lowerIsStronger ? "lower" : "higher")"),
            SummaryRow("Coverage", "\(m.n_delivered ?? cells.count) of \(m.n_cells ?? m.cells.count) cells"
                       + (m.coverage.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
        ]
        if let r = m.resolution, let floor = r.min_resolvable_difference {
            rows.append(SummaryRow("Resolution", "±" + f2(r.median_band) + " band ⇒ differences below "
                                   + f2(floor) + " are not resolved", unit: unit))
        }
        if !pending.isEmpty {
            var byState: [String: Int] = [:]
            for c in pending { byState[c.state, default: 0] += 1 }
            rows.append(SummaryRow("Not measured", byState.sorted { $0.key < $1.key }
                                                          .map { "\($0.value) \($0.key)" }
                                                          .joined(separator: ", ")))
        }

        // --- the grid, one row per ligand, every receptor across
        for lig in m.ligands {
            let parts: [String] = m.receptors.map { rec in
                guard let c = m.cell(lig, rec) else { return "\(rec) —" }
                guard let v = c.value else { return "\(rec) \(c.state)" }   // state, never 0
                return "\(rec) " + (c.tier.map { "[\($0)] " } ?? "") + f2(v) + " ± " + f2(c.uncertainty)
                    + (c.n.map { " (n=\($0))" } ?? "")
            }
            rows.append(SummaryRow(lig, parts.joined(separator: "   |   "), unit: unit))
        }

        // --- the walked column, with the scrub marker
        rows.append(SummaryRow("Column", "\(receptor) — \(cells.count) delivered, sorted by \(params.sortBy.rawValue)"))
        for (i, c) in cells.enumerated() {
            let marker = i == context.frameIndex ? "▸ " : "  "
            rows.append(SummaryRow("\(marker)cell \(i): \(c.ligand)",
                                   (c.tier.map { "tier \($0), " } ?? "") + f2(c.value) + " ± " + f2(c.uncertainty),
                                   unit: unit))
        }

        // --- selectivity: the ratio is the defensible number
        for key in m.selectivity.keys.sorted() {
            let s = m.selectivity[key]!
            let flag = (s.resolved == true) ? "" : "  (band includes \(f2(s.null)) — not a selectivity claim)"
            rows.append(SummaryRow("\(s.ligand) vs \(s.vs)",
                                   "\(s.mode) " + f2(s.value) + " ± " + f2(s.uncertainty) + flag))
        }

        // --- notes: everything the tiers should not be trusted through
        var notes: [String] = []
        notes.append("The frame axis is the cell index of column \(receptor) "
                     + "(\(cells.count) delivered cells, sorted by \(params.sortBy.rawValue)) — not time.")
        if let floor = m.resolution?.min_resolvable_difference {
            notes.append("TIERS, NOT A RANK ORDER: two cells are separated only when their bands do not overlap "
                         + "(\(m.resolution?.rule ?? "|Δv| > u_i + u_j")). The order inside a tier is not measured. "
                         + "Differences below \(f2(floor)) \(unit) are not resolved — \(m.tierCount) tier(s) here.")
        }
        if !pending.isEmpty {
            notes.append("\(pending.count) of \(m.cells.count) cells have no number and are ABSENT, not zero "
                         + "(\(pending.prefix(4).map(\.cell).joined(separator: ", "))"
                         + (pending.count > 4 ? ", …" : "") + "). An unprepared cell is not a weak cell.")
        }
        if (m.n_delivered ?? 0) < (m.n_cells ?? 0) {
            notes.append("Tiers and selectivity are computed over the delivered subset only.")
        }
        for s in m.selectivity.values.sorted(by: { $0.ligand < $1.ligand }) where s.resolved != true {
            notes.append("Selectivity \(s.ligand) vs \(s.vs) = " + f2(s.value) + " ± " + f2(s.uncertainty)
                         + " — the band includes " + f2(s.null) + ", so this row shows no selectivity.")
        }
        for c in m.compromises where c.isSerious {
            notes.append("\(c.severity.uppercased()) \(c.id): " + (c.what ?? "")
                         + ((c.effect_on_results?.isEmpty == false) ? " — \(c.effect_on_results!)" : ""))
        }
        let lesser = m.compromises.filter { !$0.isSerious }
        if !lesser.isEmpty {
            notes.append("Also \(lesser.count) medium/low compromise(s): "
                         + lesser.map(\.id).joined(separator: ", ") + " — full text in matrix.json.")
        }
        notes.append("Read from \(url.path).")

        // An EMPTY column still renders: coverage, the prep queue and the compromises are the
        // whole answer at that point, and a campaign's first day is exactly when someone looks.
        // Only a column that has something to scrub can be scrubbed past the end.
        guard !cells.isEmpty else {
            notes.append("Column \(receptor) has no delivered cell yet, so there is no value to plot — "
                         + "the coverage and prep rows above are the result. Run `campaign.py prep "
                         + "\(m.campaign ?? "<campaign>")` for the queue.")
            return ToolResult(summary: rows, scalar: nil, notes: notes)
        }
        guard context.frameIndex < cells.count else {
            throw AnalysisError.notApplicable(
                "Cell index \(context.frameIndex) is past the end of column \(receptor) (\(cells.count) delivered "
                + "cell\(cells.count == 1 ? "" : "s")). This tool plots one cell per “frame”; scrub back, pick "
                + "another receptor, or prepare more cells (`campaign.py prep`).")
        }
        return ToolResult(summary: rows, scalar: cells[context.frameIndex].value, notes: notes)
    }

    static func f2(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "—" }
}
