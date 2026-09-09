//
//  KineticsTool.swift — "Unbinding kinetics (τRAMD)".
//
//  The time-side companion to the pull-off energetics: how long the ligand
//  stays on, rather than how hard it is to pull off. Everything comes from the
//  τRAMD protocol's side files (`tramd_times.csv`, `tramd_survival.csv`) written
//  by `tramd.py`, aligned to the trajectory frame the viewer is showing — the
//  plotted scalar is the survival curve, so scrubbing the trajectory walks the
//  fraction of replicas still bound.
//
//  τ is reported with its bootstrap CI, the per-seed spread and the censored
//  fraction, and never without the rank-order caveat: τRAMD calibrates k_off
//  per target, it does not measure it.
//

import Foundation

public struct KineticsTool: AnalysisTool {
    public static let id = "kinetics_tramd"
    public static let title = "Unbinding kinetics (τRAMD)"
    public static let category = ToolCategory.adhesionBinding
    public static let functions: Set<ToolFunction> = [.scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.sideFile]
    /// The CSV is the whole computation — there is nothing to stride.
    public static let supportsStridedPreview = false

    public struct Parameters: Codable, Equatable {
        /// Explicit `tramd_times.csv`; nil = look next to `context.sourceURL`.
        public var csvPath: String?
        /// The protocol's temperature, for the record on every result.
        public var temperature_K: Double
        /// Time between trajectory frames, to map frame index → time for the
        /// survival scalar; nil = walk the CSV's own time axis.
        public var frameTime_ps: Double?

        public init(csvPath: String? = nil, temperature_K: Double = 300, frameTime_ps: Double? = nil) {
            self.csvPath = csvPath
            self.temperature_K = temperature_K
            self.frameTime_ps = frameTime_ps
        }
    }

    public static let defaultParameters = Parameters()

    /// A cached CSV lookup and a bootstrap over a few dozen numbers — independent of N.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 60 }

    // MARK: - Resolution

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Where `analyze` looked — quoted to the user, because
    /// `.missingRequirement(.sideFile)` carries no message of its own.
    public static func searchNote(context: AnalysisContext, params: Parameters) -> String {
        if let p = params.csvPath { return "Looked for the τRAMD times at \(expand(p).path)." }
        guard let src = context.sourceURL else {
            return "No trajectory file path is known, so there is nowhere to look for tramd_times.csv — set csvPath."
        }
        return "No tramd_times.csv found. Looked in: "
            + RAMDResults.searchLocations(near: src).map { $0.path }.joined(separator: ", ") + "."
    }

    static func resolveCSV(context: AnalysisContext, params: Parameters) -> URL? {
        if let p = params.csvPath {
            let u = expand(p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard let src = context.sourceURL else { return nil }
        return RAMDResults.locate(near: src)
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let csvURL = resolveCSV(context: context, params: params),
              let results = try? RAMDResults.load(csvURL), !results.replicas.isEmpty
        else { throw AnalysisError.missingRequirement(.sideFile) }

        let seeds = results.seeds
        let n = results.replicas.count
        let dissociated = results.replicas.filter { !$0.censored }.count

        var rows: [SummaryRow] = []
        if let tau = results.tau {
            if let ci = results.bootstrapCI() {
                rows.append(SummaryRow("Residence time τ",
                                       "\(g4(tau)) [95 % CI \(g4(ci.lo))–\(g4(ci.hi))]", unit: "ps"))
            } else {
                rows.append(SummaryRow("Residence time τ", "\(g4(tau)) (no CI: too few usable resamples)", unit: "ps"))
            }
            rows.append(SummaryRow("k_off (relative)", "\(g4(1 / tau)) — rank order within this target only", unit: "ps⁻¹"))
        } else {
            rows.append(SummaryRow("Residence time τ",
                                   "undefined — only \(dissociated) of \(n) replicas dissociated (need ≥ half)"))
            rows.append(SummaryRow("k_off (relative)", "n/a — τ undefined"))
        }

        let perSeed = results.tauPerSeed.map { entry -> String in
            "\(entry.seed): " + (entry.tau.map { g4($0) } ?? "n/a")
        }.joined(separator: " · ")
        rows.append(SummaryRow("τ per seed", perSeed.isEmpty ? "none" : perSeed, unit: "ps"))
        rows.append(SummaryRow("Replicas",
                               "\(n) over \(seeds.count) seed\(seeds.count == 1 ? "" : "s") "
                               + "(\(seeds.map { "\($0.dissociated)/\($0.count)" }.joined(separator: ", ")) dissociated)"))
        rows.append(SummaryRow("Censored",
                               "\(n - dissociated) of \(n) (\(g4(100 * results.censoredFraction)) %) — still bound at "
                               + "\(g4(results.maxTime_ps)) ps"))
        rows.append(SummaryRow("Method", "τRAMD (Kokh et al. 2018) at \(g4(params.temperature_K)) K; "
                               + "τ = mean over seeds of the interpolated 50 % dissociation time"))

        // --- frame → time → survival (the plotted scalar IS the survival curve)
        let t = results.time(forFrame: context.frameIndex, frameTime_ps: params.frameTime_ps)
        var notes = [RAMDResults.koffCaveat]
        var scalar: Double?
        if let t {
            scalar = results.fractionBound(at: t)
            rows.append(SummaryRow("Bound at t = \(g4(t)) ps", g4(scalar!), unit: "fraction"))
            if let dt = params.frameTime_ps, dt > 0 {
                notes.append("Alignment: frame \(context.frameIndex) × \(g4(dt)) ps = \(g4(t)) ps.")
            } else {
                notes.append("Alignment: no frame interval given, so frame \(context.frameIndex) walks the "
                             + "\(results.survival.isEmpty ? "dissociation-time" : "survival-file") axis to \(g4(t)) ps "
                             + "— set frameTime_ps for a true time axis.")
            }
        } else {
            notes.append("No time axis: tramd_times.csv has no usable times, so no survival value for this frame.")
        }
        if results.survival.isEmpty {
            notes.append("No tramd_survival.csv beside the times — the survival curve is pooled from the replica times.")
        }
        if results.censoredFraction > 0.5 {
            notes.append("More than half the replicas were censored: τ is a lower bound, not an estimate.")
        }

        return ToolResult(summary: rows, scalar: scalar, notes: notes)
    }

    // MARK: - Formatting

    static func g4(_ x: Double) -> String { String(format: "%.4g", x) }
}
