//
//  PullOffEnergeticsTool.swift — design §2.4, "Pull-off energetics".
//
//  Force-side adhesion: everything here comes from the SMD protocol's side
//  file `force_curve.csv` (+ `config.json`), aligned to the trajectory frame
//  the viewer is showing. Rupture force F* and work of separation W per seed,
//  reported as distributions; Bell–Evans only with ≥ 3 velocities; Jarzynski
//  only with ≥ 10 pulls at a confirm rate. Everything else is labelled as the
//  single non-equilibrium work it is.
//

import Foundation

public struct PullOffEnergeticsTool: AnalysisTool {
    public static let id = "pulloff_energetics"
    public static let title = "Pull-off energetics"
    public static let category = ToolCategory.adhesionBinding
    public static let functions: Set<ToolFunction> = [.scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.sideFile]
    /// The CSV row is the whole computation — there is nothing to stride.
    public static let supportsStridedPreview = false

    /// Frame ↔ CSV row mapping. The protocol writes both at the same cadence,
    /// so `row` is right unless the trajectory was decimated.
    public enum FrameAlignment: String, Codable, CaseIterable {
        case row, time
    }

    public struct Parameters: Codable, Equatable {
        /// Explicit `force_curve.csv`; nil = look next to `context.sourceURL`.
        public var csvPath: String?
        /// Which seed's pull to show; nil = the one that fits the frame count.
        public var seed: Int?
        public var frameAlignment: FrameAlignment
        /// Time between trajectory frames, for `.time` alignment; nil = the
        /// run's `report_interval_ps`, else the CSV's own spacing.
        public var frameInterval_ps: Double?
        /// Extra run directories (each with its own config.json +
        /// force_curve.csv) pooled for Bell–Evans and Jarzynski.
        public var runDirs: [String]
        public var temperature_K: Double

        public init(csvPath: String? = nil, seed: Int? = nil,
                    frameAlignment: FrameAlignment = .row, frameInterval_ps: Double? = nil,
                    runDirs: [String] = [], temperature_K: Double = 300) {
            self.csvPath = csvPath
            self.seed = seed
            self.frameAlignment = frameAlignment
            self.frameInterval_ps = frameInterval_ps
            self.runDirs = runDirs
            self.temperature_K = temperature_K
        }
    }

    public static let defaultParameters = Parameters()

    /// A parsed, cached CSV lookup and a little arithmetic — independent of N.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 40 }

    /// SMD is not AFM, and the tool says so on every result.
    public static let rateCaveat =
        "SMD loading rates are 10^6–10^9× AFM; F* is not an experimental number."

    // MARK: - Resolution

    /// One run's side files.
    struct RunSample {
        let name: String
        let curve: ForceCurve
        let config: RunConfig?
        var velocity_A_per_ns: Double? { config?.pullVelocity_A_per_ns }
        var loadingRate_pN_per_s: Double? { config?.loadingRate_pN_per_s }
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Where `analyze` looks for the side file — quoted to the user when the
    /// throw is `.missingRequirement(.sideFile)`, which carries no message.
    public static func searchNote(context: AnalysisContext, params: Parameters) -> String {
        if let p = params.csvPath { return "Looked for the force curve at \(expand(p).path)." }
        guard let src = context.sourceURL else {
            return "No trajectory file path is known, so there is nowhere to look for force_curve.csv — set csvPath."
        }
        let paths = ForceCurve.searchLocations(near: src).map { $0.path }
        return "No force_curve.csv found. Looked in: " + paths.joined(separator: ", ") + "."
    }

    static func resolveCSV(context: AnalysisContext, params: Parameters) -> URL? {
        if let p = params.csvPath {
            let u = expand(p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard let src = context.sourceURL else { return nil }
        return ForceCurve.locate(near: src)
    }

    static func sample(csv: URL, name: String) -> RunSample? {
        guard let curve = try? ForceCurve.load(csv), !curve.seeds.isEmpty else { return nil }
        let config = RunConfig.locate(near: csv).flatMap { try? RunConfig.load($0) }
        return RunSample(name: name, curve: curve, config: config)
    }

    /// The seed to display: the caller's, else the shortest one that still
    /// contains this frame index, else the first in the file.
    static func pickSeed(_ curve: ForceCurve, frameIndex: Int, requested: Int?) -> ForceCurve.Seed? {
        if let r = requested, let s = curve.seed(r) { return s }
        let fitting = curve.seeds.filter { $0.count > frameIndex }
        return fitting.min { $0.count < $1.count } ?? curve.seeds.first
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let csvURL = resolveCSV(context: context, params: params),
              let primary = sample(csv: csvURL, name: csvURL.deletingLastPathComponent().lastPathComponent)
        else { throw AnalysisError.missingRequirement(.sideFile) }

        guard let seed = pickSeed(primary.curve, frameIndex: context.frameIndex, requested: params.seed),
              seed.count > 0
        else { throw AnalysisError.notApplicable("force_curve.csv has no usable rows (\(csvURL.path)).") }

        // --- frame → row
        let interval = params.frameInterval_ps ?? primary.config?.reportInterval_ps ?? seed.reportInterval_ps
        let row: Int
        switch params.frameAlignment {
        case .row:
            guard context.frameIndex < seed.count else {
                throw AnalysisError.notApplicable(
                    "Frame \(context.frameIndex) is past the end of force_curve.csv (seed \(seed.seed) has \(seed.count) rows). "
                    + "The trajectory and the force curve were written at different cadences — set frameAlignment to “time”.")
            }
            row = context.frameIndex
        case .time:
            guard let dt = interval, dt > 0 else {
                throw AnalysisError.notApplicable(
                    "Time alignment needs a frame interval: set frameInterval_ps (no report_interval_ps in config.json).")
            }
            let target = seed.time_ps[0] + Double(context.frameIndex) * dt
            guard let nearest = seed.time_ps.indices.min(by: {
                abs(seed.time_ps[$0] - target) < abs(seed.time_ps[$1] - target)
            }), abs(seed.time_ps[nearest] - target) <= dt else {
                throw AnalysisError.notApplicable(
                    "No force-curve row near t = \(g4(target)) ps (frame \(context.frameIndex) × \(g4(dt)) ps); the curve ends at \(g4(seed.time_ps.last ?? 0)) ps.")
            }
            row = nearest
        }

        // --- pooled runs, for the loading-rate and free-energy questions
        var samples = [primary]
        for dir in params.runDirs {
            let u = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            guard let csv = ForceCurve.locate(near: u),
                  csv.standardizedFileURL != csvURL.standardizedFileURL,
                  let s = sample(csv: csv, name: u.lastPathComponent) else { continue }
            samples.append(s)
        }

        var rows: [SummaryRow] = [
            SummaryRow("Time", g4(seed.time_ps[row]), unit: "ps"),
            SummaryRow("Reference displacement", g4(seed.refDisp[row]), unit: "nm"),
            SummaryRow("COM displacement", g4(seed.comDisp[row]), unit: "nm"),
            SummaryRow("Spring force", g4(seed.force_pN[row]), unit: "pN"),
            SummaryRow("Running work", g4(seed.work[row]), unit: "kJ/mol"),
            SummaryRow("Contacts", "\(seed.contacts[row])")
        ]

        if let peak = Energetics.ruptureForce(seed) {
            rows.append(SummaryRow("Rupture force F*", "\(g4(peak.Fstar)) (frame \(peak.index))", unit: "pN"))
        }
        if let w = Energetics.workOfSeparation(seed) {
            rows.append(SummaryRow("Work of separation W",
                                   "\(g4(w.csv)) CSV ∫F·dx_ref · \(g4(w.trapezoid)) trapezoid ∫F·dx_COM",
                                   unit: "kJ/mol"))
        }
        if let r = Energetics.ruptureIndex(seed) {
            rows.append(SummaryRow("Rupture frame", "\(r) (t = \(g4(seed.time_ps[r])) ps)"))
        } else {
            rows.append(SummaryRow("Rupture frame", "none — contacts never reach zero and stay"))
        }
        rows.append(SummaryRow("Seed", "\(seed.seed) (\(primary.curve.seeds.count) in this file)"))
        if let v = primary.velocity_A_per_ns { rows.append(SummaryRow("Pull velocity", g4(v), unit: "Å/ns")) }
        if let k = primary.config?.springK_kJ_mol_nm2 {
            rows.append(SummaryRow("Spring constant k", g4(k), unit: "kJ/mol/nm²"))
        }

        // --- distributions across seeds (never a bare mean)
        if primary.curve.seeds.count >= 2 {
            let fs = primary.curve.seeds.compactMap { Energetics.ruptureForce($0)?.Fstar }
            let ws = primary.curve.seeds.compactMap { Energetics.workOfSeparation($0)?.csv }
            if fs.count >= 2 { rows.append(SummaryRow("F* across seeds", distribution(fs), unit: "pN")) }
            if ws.count >= 2 { rows.append(SummaryRow("W across seeds", distribution(ws), unit: "kJ/mol")) }
        }

        rows.append(bellEvansRow(samples, temperature_K: params.temperature_K))
        rows.append(jarzynskiRow(samples, temperature_K: params.temperature_K))

        var notes = [rateCaveat]
        if let v = primary.velocity_A_per_ns {
            notes.append("Pull velocity \(g4(v)) Å/ns" + (v > 1 ? " (screen rate — rank order only)." : " (confirm rate)."))
        } else {
            notes.append("No config.json found next to the force curve — pull velocity unknown.")
        }
        switch params.frameAlignment {
        case .row:
            notes.append("Alignment: frame i ↔ CSV row i (seed \(seed.seed), \(seed.count) rows).")
        case .time:
            notes.append("Alignment: by time_ps at \(g4(interval ?? 0)) ps per frame → row \(row) of \(seed.count).")
        }
        if samples.count > 1 { notes.append("Pooled \(samples.count) runs for the rate/free-energy rows.") }

        // The whole force curve as a frame-indexed series: the chart appears at once and
        // tracks playback, no per-frame re-run needed (design §2.4 "F(t) with the cursor").
        var series: [Int: Double] = [:]
        switch params.frameAlignment {
        case .row:
            for i in 0..<seed.count { series[i] = seed.force_pN[i] }
        case .time:
            if let dt = interval, dt > 0 {
                let t0 = seed.time_ps[0]
                for i in 0..<seed.count {
                    let f = Int(((seed.time_ps[i] - t0) / dt).rounded())
                    if series[f] == nil { series[f] = seed.force_pN[i] }
                }
            }
        }
        return ToolResult(summary: rows, scalar: seed.force_pN[row], notes: notes,
                          series: series, seriesLabel: "Spring force (pN)")
    }

    // MARK: - Gated rows

    static func bellEvansRow(_ samples: [RunSample], temperature_K: Double) -> SummaryRow {
        // One point per distinct loading rate: median F* over every seed at it.
        var byRate: [Double: [Double]] = [:]
        for s in samples {
            guard let r = s.loadingRate_pN_per_s, r > 0 else { continue }
            byRate[r, default: []] += s.curve.seeds.compactMap { Energetics.ruptureForce($0)?.Fstar }
        }
        let points = byRate.compactMap { rate, fs -> (loadingRate: Double, Fstar: Double)? in
            fs.isEmpty ? nil : (rate, Energetics.median(fs))
        }
        guard let fit = Energetics.bellEvans(points: points, temperature_K: temperature_K) else {
            let n = points.count
            return SummaryRow("Bell–Evans", "n/a: \(n) velocit\(n == 1 ? "y" : "ies") — need ≥ 3")
        }
        return SummaryRow("Bell–Evans",
                          "x_β = \(g4(fit.xBeta_nm)) nm, k_off⁰ = \(g4(fit.koff0)) s⁻¹ "
                          + "(slope \(g4(fit.slope)) pN per ln r, \(points.count) velocities)")
    }

    static func jarzynskiRow(_ samples: [RunSample], temperature_K: Double) -> SummaryRow {
        // Confirm rate only: ≤ 1 Å/ns, where the dissipation is small enough
        // for the exponential average to have a chance.
        var works: [Double] = []
        for s in samples {
            guard let v = s.velocity_A_per_ns, v <= 1.0 else { continue }
            works += s.curve.seeds.compactMap { Energetics.workOfSeparation($0)?.csv }
        }
        let kT = Energetics.kT_kJ_per_mol(temperature_K)
        guard let j = Energetics.jarzynski(works: works, kT: kT) else {
            return SummaryRow("Free energy",
                              "work, single pull — not a free energy (\(works.count) pull\(works.count == 1 ? "" : "s") at ≤ 1 Å/ns; need ≥ 10)")
        }
        return SummaryRow("Jarzynski ΔF",
                          "\(g4(j.deltaF)) (2nd-order cumulant \(g4(j.secondOrderCumulant))), \(works.count) pulls at ≤ 1 Å/ns",
                          unit: "kJ/mol")
    }

    // MARK: - Formatting

    static func g4(_ x: Double) -> String { String(format: "%.4g", x) }

    static func distribution(_ xs: [Double]) -> String {
        let q = Energetics.iqr(xs)
        return "median \(g4(Energetics.median(xs))) [IQR \(g4(q.q1))–\(g4(q.q3))], n = \(xs.count)"
    }
}
