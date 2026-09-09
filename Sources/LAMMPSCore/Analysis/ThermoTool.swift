//
//  ThermoTool.swift — the run's own log as a study, and the stress–strain
//  curve that lives only there.
//
//  Two jobs. First, put the thermo table next to the trajectory: scrub to a
//  frame and see the temperature, energy and pressure LAMMPS printed at that
//  step, with the scalar following playback so the chart is a real time axis.
//
//  Second, the mechanical test. A `fix deform` run writes L(step) and P(step);
//  engineering strain is L/L₀ − 1 along the pulled axis and the stress is −P
//  (LAMMPS reports pressure, and a positive pressure is compression), in bar,
//  which is 1e-4 GPa. Young's modulus is the slope over the first per cent or
//  two of strain, before anything yields — the tool reports the fit range with
//  the number so a modulus read off a plastic segment is visible as such.
//

import Foundation

public struct ThermoTool: AnalysisTool {
    public static let id = "thermo"
    public static let title = "Thermo (log.lammps)"
    public static let category = ToolCategory.mechanicsDeformation
    public static let functions: Set<ToolFunction> = [.scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.sideFile]
    public static let supportsStridedPreview = false

    public struct Parameters: Codable, Equatable {
        /// Explicit log; nil = look for `log.lammps` (then `*.log` / `log.*`)
        /// beside the trajectory.
        public var logPath: String?
        public var xColumn: String
        public var yColumns: [String]
        /// Derive a stress–strain curve when the columns allow it.
        public var stressStrain: Bool
        /// Strain window used for Young's modulus, from the start of the curve.
        public var elasticStrain: Double
        /// "step" = match the frame's timestep to a thermo Step (nearest);
        /// "index" = frame i is row i.
        public var alignBy: String

        public init(logPath: String? = nil, xColumn: String = "Step",
                    yColumns: [String] = ["Temp", "PotEng", "Press"],
                    stressStrain: Bool = true, elasticStrain: Double = 0.02,
                    alignBy: String = "step") {
            self.logPath = logPath
            self.xColumn = xColumn
            self.yColumns = yColumns
            self.stressStrain = stressStrain
            self.elasticStrain = elasticStrain
            self.alignBy = alignBy
        }
    }

    public static let defaultParameters = Parameters()

    /// Independent of atom count — the work is one (cached) file parse.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 50 }

    /// 1 bar = 1e-4 GPa.
    public static let GPaPerBar = 1e-4

    // MARK: - Stress–strain

    public struct StressStrain: Equatable {
        public let axis: String                 // "x" | "y" | "z"
        public let strain: [Double]             // engineering, L/L₀ − 1
        public let stress_GPa: [Double]         // −P along that axis
        public let youngsModulus_GPa: Double
        public let fitPoints: Int
        public let fitStrainMax: Double
        public let maxStress_GPa: Double

        public var strainAtMaxStress: Double {
            guard let i = stress_GPa.firstIndex(of: maxStress_GPa), i < strain.count else { return .nan }
            return strain[i]
        }
    }

    /// Length and pressure column names LAMMPS uses per axis, plus the
    /// `c_*`/`v_*` aliases a custom `thermo_style` tends to give them.
    static let axisColumns: [(axis: String, length: [String], pressure: [String])] = [
        ("x", ["Lx", "v_lx", "c_lx"], ["Pxx", "v_pxx", "c_pxx", "v_sxx", "c_sxx"]),
        ("y", ["Ly", "v_ly", "c_ly"], ["Pyy", "v_pyy", "c_pyy", "v_syy", "c_syy"]),
        ("z", ["Lz", "v_lz", "c_lz"], ["Pzz", "v_pzz", "c_pzz", "v_szz", "c_szz"])
    ]

    /// The axis that actually moved, and its curve. Nil when the log carries no
    /// matching L/P pair or nothing was deformed.
    public static func stressStrain(_ log: LammpsLog, elasticStrain: Double) -> StressStrain? {
        let common = Set(log.commonColumns)
        var best: StressStrain?
        var bestRange = 0.0
        for entry in axisColumns {
            guard let lName = entry.length.first(where: { common.contains($0) }),
                  let pName = entry.pressure.first(where: { common.contains($0) }),
                  let lengths = log.column(lName), let pressures = log.column(pName),
                  let l0 = lengths.first, l0 > 0, lengths.count >= 3 else { continue }
            let strain = lengths.map { $0 / l0 - 1 }
            guard let lo = strain.min(), let hi = strain.max(), hi - lo > 1e-9 else { continue }
            guard hi - lo > bestRange else { continue }
            let stress = pressures.map { -$0 * GPaPerBar }

            // Elastic window: from the first point, out to `elasticStrain` of
            // strain travelled (in whichever direction the run pulled).
            let sign: Double = (strain.last ?? 0) >= strain[0] ? 1 : -1
            var xs: [Double] = [], ys: [Double] = []
            var reached = 0.0
            for i in 0..<min(strain.count, stress.count) {
                let travelled = sign * (strain[i] - strain[0])
                guard travelled <= max(elasticStrain, 0) else { break }
                xs.append(strain[i]); ys.append(stress[i]); reached = travelled
            }
            let (slope, _) = DiffusionTool.leastSquaresSlope(x: xs, y: ys)
            bestRange = hi - lo
            best = StressStrain(axis: entry.axis, strain: strain, stress_GPa: stress,
                                youngsModulus_GPa: slope, fitPoints: xs.count,
                                fitStrainMax: reached,
                                maxStress_GPa: stress.max() ?? .nan)
        }
        return best
    }

    // MARK: - Alignment

    /// Concatenated-row index for this frame. `step` matches the frame's
    /// timestep against the log's Step column (nearest row wins, which is what
    /// a dump every 100 steps against thermo every 250 needs); `index` is the
    /// naive frame i ↔ row i.
    static func rowIndex(log: LammpsLog, frame: Frame, frameIndex: Int, params: Parameters) -> Int? {
        let total = log.rowCount
        guard total > 0 else { return nil }
        if params.alignBy == "index" { return min(max(0, frameIndex), total - 1) }
        guard let ts = frame.timestep, let steps = log.column(params.xColumn), !steps.isEmpty else {
            return min(max(0, frameIndex), total - 1)
        }
        var best = 0, bestDistance = Double.infinity
        for (i, s) in steps.enumerated() {
            let d = abs(s - Double(ts))
            if d < bestDistance { bestDistance = d; best = i }
            if d == 0 { break }
        }
        return best
    }

    /// The log this call should read: the explicit `logPath` when it exists,
    /// else the search beside the trajectory. Nil = nothing to read.
    public static func resolveLog(context: AnalysisContext, params: Parameters) -> URL? {
        if let path = params.logPath, !path.isEmpty {
            let candidate = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        return context.sourceURL.flatMap { LammpsLog.locate(near: $0) }
    }

    /// Where the tool looked, for the "no side file" panel.
    public static func searchLocations(context: AnalysisContext) -> [URL] {
        context.sourceURL.map { LammpsLog.searchLocations(near: $0) } ?? []
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        // Same contract as the pull-off tool: a missing side file is
        // `.missingRequirement(.sideFile)` (the inspector greys the tool out
        // and shows where it looked), not a message about the data.
        guard let url = resolveLog(context: context, params: params) else {
            throw AnalysisError.missingRequirement(.sideFile)
        }

        let log: LammpsLog
        do { log = try LammpsLog.load(url) }
        catch { throw AnalysisError.notApplicable("Could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        guard !log.isEmpty else {
            throw AnalysisError.notApplicable("\(url.lastPathComponent) has no thermo table (no “Step …” header).")
        }

        var notes: [String] = []
        let common = Set(log.commonColumns)
        guard common.contains(params.xColumn) else {
            throw AnalysisError.notApplicable(
                "No column “\(params.xColumn)” in every run of \(url.lastPathComponent) "
                + "(have: \(log.allColumns.joined(separator: ", "))).")
        }
        let usableY = params.yColumns.filter { common.contains($0) }
        let droppedY = params.yColumns.filter { !common.contains($0) }
        if !droppedY.isEmpty {
            notes.append("Not in every run's thermo_style, so not shown: \(droppedY.joined(separator: ", ")).")
        }

        let row = rowIndex(log: log, frame: frame, frameIndex: context.frameIndex, params: params)
        let curve = params.stressStrain ? stressStrain(log, elasticStrain: params.elasticStrain) : nil

        func fmt(_ x: Double?, _ digits: Int = 4) -> String {
            guard let x, x.isFinite else { return "—" }
            return String(format: "%.\(digits)g", x)
        }
        var summary: [SummaryRow] = [
            SummaryRow("Log", url.lastPathComponent),
            SummaryRow("Runs × rows", "\(log.blocks.count) × \(log.rowCount)")
        ]
        if let row {
            let blockOf = log.rowBlockIndex
            summary.append(SummaryRow(params.xColumn, fmt(log.column(params.xColumn)?[row], 8)))
            if log.blocks.count > 1, row < blockOf.count {
                summary.append(SummaryRow("Run", "\(blockOf[row] + 1) of \(log.blocks.count)"))
            }
            for name in usableY {
                summary.append(SummaryRow(name, fmt(log.column(name)?[row])))
            }
            summary.append(SummaryRow("Aligned by",
                                      params.alignBy == "index" ? "frame index" : "timestep → nearest Step"))
        } else {
            notes.append("This frame could not be matched to a thermo row.")
        }

        var scalar: Double? = row.flatMap { r in usableY.first.flatMap { log.column($0)?[r] } }
        if let curve {
            summary.append(SummaryRow("Deformed axis", curve.axis))
            if let row, row < curve.strain.count {
                summary.append(SummaryRow("Strain (this frame)", fmt(curve.strain[row] * 100, 3), unit: "%"))
                summary.append(SummaryRow("Stress (this frame)", fmt(curve.stress_GPa[row]), unit: "GPa"))
                scalar = curve.stress_GPa[row]
            }
            summary.append(SummaryRow("Young's modulus E", fmt(curve.youngsModulus_GPa), unit: "GPa"))
            summary.append(SummaryRow("E fit range",
                                      "\(curve.fitPoints) rows, strain ≤ \(fmt(curve.fitStrainMax * 100, 3)) %"))
            summary.append(SummaryRow("Max stress", fmt(curve.maxStress_GPa), unit: "GPa"))
            summary.append(SummaryRow("at strain", fmt(curve.strainAtMaxStress * 100, 3), unit: "%"))
            if curve.fitPoints < 3 {
                notes.append("Fewer than three rows inside elasticStrain = \(fmt(params.elasticStrain)) — "
                             + "E is not fitted. Widen the window or print thermo more often.")
            }
            notes.append("Stress is −P (LAMMPS prints pressure; compression is positive), "
                         + "bar → GPa ×1e-4. Strain is engineering, L/L₀ − 1.")
        } else if params.stressStrain {
            notes.append("No stress–strain: the log needs a length (Lx/Ly/Lz) and a matching "
                         + "pressure (Pxx/Pyy/Pzz) column in every run, and a box that actually changed.")
        }

        return ToolResult(summary: summary, field: nil, profile: nil, scalar: scalar, notes: notes)
    }
}
