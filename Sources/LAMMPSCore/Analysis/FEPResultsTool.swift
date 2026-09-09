//
//  FEPResultsTool.swift — read an RBFE (FEP) network back into the inspector.
//
//  The whole computation happened on a GPU somewhere else; this tool's job is
//  to show what came back and to be honest about which edges are not
//  trustworthy. Ranked ligands first (that is the deliverable), then the edges
//  that produced the ranking, then the cycle closures that say whether the
//  network agrees with itself.
//
//  The "frame" axis is the EDGE INDEX here, not time: `scalar` is the ΔΔG of
//  the edge at `context.frameIndex` in the current sort order, so scrubbing
//  walks the network edge by edge and the time-series chart is a ΔΔG bar per
//  edge with the marker on the current one.
//

import Foundation

public struct FEPResultsTool: AnalysisTool {
    public static let id = "fep_results"
    public static let title = "FEP results (ΔΔG)"
    public static let category = ToolCategory.adhesionBinding
    public static let functions: Set<ToolFunction> = [.scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.sideFile]
    /// A JSON read and some sorting — nothing scales with atom count.
    public static let supportsStridedPreview = false

    public enum SortBy: String, Codable, CaseIterable {
        /// Edges in the ranked order of their ligands (the deliverable's order).
        case rank
        /// Most negative ΔΔG first.
        case ddG
        /// Largest uncertainty first — the re-run queue.
        case error
    }

    public struct Parameters: Codable, Equatable {
        /// Explicit `results.json`; nil = look next to `context.sourceURL`.
        public var jsonPath: String?
        public var sortBy: SortBy
        public init(jsonPath: String? = nil, sortBy: SortBy = .rank) {
            self.jsonPath = jsonPath
            self.sortBy = sortBy
        }
    }

    public static let defaultParameters = Parameters()
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 40 }

    /// Gate thresholds, mirrored from delivery/fep/README.md so the viewer
    /// flags what the pipeline flags even when `converged` is absent.
    public static let overlapFloor = 0.03
    public static let closureMax = 1.0

    // MARK: - Resolution

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Quoted to the user when the throw is `.missingRequirement(.sideFile)`,
    /// which carries no message of its own.
    public static func searchNote(context: AnalysisContext, params: Parameters) -> String {
        if let p = params.jsonPath { return "Looked for the FEP results at \(expand(p).path)." }
        guard let src = context.sourceURL else {
            return "No trajectory file path is known, so there is nowhere to look for results.json — set jsonPath."
        }
        return "No results.json found. Looked in: "
            + FEPResults.searchLocations(near: src).map { $0.path }.joined(separator: ", ") + "."
    }

    static func resolveJSON(context: AnalysisContext, params: Parameters) -> URL? {
        if let p = params.jsonPath {
            let u = expand(p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard let src = context.sourceURL else { return nil }
        return FEPResults.locate(near: src)
    }

    /// Edge order for both the table and the `scalar` axis.
    static func sorted(_ results: FEPResults, by key: SortBy) -> [FEPResults.Edge] {
        let rank = Dictionary(results.ranked.enumerated().map { ($1.name, $0) },
                              uniquingKeysWith: { first, _ in first })
        switch key {
        case .rank:
            return results.edges.sorted {
                let a = min(rank[$0.ligA] ?? .max, rank[$0.ligB] ?? .max)
                let b = min(rank[$1.ligA] ?? .max, rank[$1.ligB] ?? .max)
                return a == b ? $0.name < $1.name : a < b
            }
        case .ddG:
            return results.edges.sorted {
                ($0.ddG_kcal ?? .greatestFiniteMagnitude) < ($1.ddG_kcal ?? .greatestFiniteMagnitude)
            }
        case .error:
            return results.edges.sorted { ($0.ddG_err ?? -1) > ($1.ddG_err ?? -1) }
        }
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let url = resolveJSON(context: context, params: params),
              let results = try? FEPResults.load(url)
        else { throw AnalysisError.missingRequirement(.sideFile) }
        guard !results.edges.isEmpty else {
            throw AnalysisError.notApplicable("\(url.lastPathComponent) has no edges — the network has not been analysed yet.")
        }

        let edges = sorted(results, by: params.sortBy)
        var rows: [SummaryRow] = [
            SummaryRow("Force field", results.forcefield ?? "unknown"),
            SummaryRow("Network", "\(results.ligands.count) ligands, \(edges.count) edges"
                       + (results.isDemo ? " — DEMO DATA" : ""))
        ]
        if let s = results.settings, !s.isEmpty {
            rows.append(SummaryRow("Settings", s.keys.sorted().map { "\($0) \(s[$0]!.text)" }
                                                    .joined(separator: ", ")))
        }
        if let p = results.provenance {
            let parts = [p.openfe.map { "openfe \($0)" }, p.openmm.map { "openmm \($0)" },
                         p.openff.map { "openff \($0)" }, p.cinnabar.map { "cinnabar \($0)" },
                         p.date, p.host].compactMap { $0 }
            if !parts.isEmpty { rows.append(SummaryRow("Provenance", parts.joined(separator: " · "))) }
        }
        if let m = results.absolute_method { rows.append(SummaryRow("Absolute ΔG", m)) }

        for lig in results.ranked {
            rows.append(SummaryRow("#\(lig.rank.map(String.init) ?? "?")  \(lig.name)",
                                   f2(lig.dG_abs_kcal) + " ± " + f2(lig.dG_abs_err), unit: "kcal/mol"))
        }

        for (i, e) in edges.enumerated() {
            let marker = i == context.frameIndex ? "▸ " : "  "
            var text = "ΔΔG " + f2(e.ddG_kcal) + " ± " + f2(e.ddG_err)
            if let o = e.overlap_min { text += ", overlap \(String(format: "%.3f", o))" }
            if let s = e.dG_solvent { text += ", solvent " + f2(s) }
            if let c = e.dG_complex { text += ", complex " + f2(c) }
            if e.converged == false { text += ", NOT CONVERGED" }
            rows.append(SummaryRow("\(marker)edge \(i): \(e.name)", text, unit: "kcal/mol"))
        }

        for c in (results.cycles ?? []) {
            let flag = abs(c.closure_kcal ?? 0) > closureMax ? "  ✗" : ""
            rows.append(SummaryRow("Cycle \(c.ligands.joined(separator: "–"))",
                                   f2(c.closure_kcal) + " ± " + f2(c.closure_err) + flag, unit: "kcal/mol"))
        }

        // --- notes: everything the ranking should not be trusted through
        var notes: [String] = []
        if results.isDemo {
            notes.append("DEMO DATA — synthetic numbers from `analyze --demo`, not a simulation result.")
        }
        notes.append("The frame axis is the edge index (\(edges.count) edges, sorted by \(params.sortBy.rawValue)) — not time.")
        for e in edges {
            var why: [String] = []
            if e.converged == false { why.append("did not converge") }
            if let o = e.overlap_min, o < overlapFloor {
                why.append("overlap min \(String(format: "%.3f", o)) < \(String(format: "%.2f", overlapFloor))")
            }
            if !why.isEmpty {
                let detail = (e.notes?.isEmpty == false) ? " (\(e.notes!))" : ""
                notes.append("Edge \(e.name): " + why.joined(separator: ", ") + detail + " — re-run before ranking on it.")
            }
        }
        for c in (results.cycles ?? []) where abs(c.closure_kcal ?? 0) > closureMax {
            notes.append("Cycle \(c.ligands.joined(separator: "–")) closes at "
                         + f2(c.closure_kcal) + " kcal/mol (> \(String(format: "%.1f", closureMax))) — the network disagrees with itself.")
        }
        notes += results.flags ?? []
        notes.append("ΔG per ligand is relative to the network mean, not an absolute affinity.")
        notes.append("Read from \(url.path).")

        guard context.frameIndex < edges.count else {
            throw AnalysisError.notApplicable(
                "Edge index \(context.frameIndex) is past the end of the network (\(edges.count) edges). "
                + "This tool plots one edge per “frame”; load a trajectory with at most \(edges.count) frames, or scrub back.")
        }
        return ToolResult(summary: rows, scalar: edges[context.frameIndex].ddG_kcal, notes: notes)
    }

    static func f2(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "—" }
}
