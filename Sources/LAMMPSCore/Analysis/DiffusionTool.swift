//
//  DiffusionTool.swift — mean squared displacement and the Einstein diffusion
//  coefficient.
//
//  MSD(t) = ⟨|r(t) − r(0)|²⟩ and, in the linear (Fickian) regime,
//  MSD = 6·D·t in three dimensions. The factor is 2d, so a 2D or 1D reading of
//  the same data would use 4 or 2 — this tool is 3D and says so, because the
//  single commonest way to be wrong by 3× about a diffusion coefficient is to
//  disagree silently about that factor.
//
//  The other way to be wrong is wrapping. A periodic dump folds atoms back
//  into the cell, so a raw r(t) − r(0) saturates at the box diagonal and D
//  collapses to zero at long times. `unwrap` (on by default) accumulates the
//  minimum-image step between CONSECUTIVE frames instead, which is exact as
//  long as no atom moves more than half a box in one dump interval — the
//  standard caveat, and one the tool repeats in a note.
//

import Foundation

public struct DiffusionTool: AnalysisTool {
    public static let id = "diffusion"
    public static let title = "Diffusion (MSD)"
    public static let category = ToolCategory.mechanicsDeformation
    public static let functions: Set<ToolFunction> = [.perAtomField, .scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.referenceFrame]
    /// Striding changes which atoms are averaged, not what is measured: MSD of
    /// a random subset is the same quantity, just noisier.
    public static let supportsStridedPreview = true

    public struct Parameters: Codable, Equatable {
        /// Element to follow; nil = every atom.
        public var species: String?
        /// Femtoseconds per LAMMPS timestep — the dump's `timestep` times this
        /// is the physical time.
        public var timestep_fs: Double
        /// Used only when frames carry no timestep: time = frame index × this.
        public var frameInterval_ps: Double
        /// Skip this fraction of the series before fitting (the ballistic /
        /// caging head is not Fickian and would bias D upwards).
        public var fitStartFraction: Double
        /// Undo periodic wrapping between consecutive frames.
        public var unwrap: Bool

        public init(species: String? = nil, timestep_fs: Double = 1.0,
                    frameInterval_ps: Double = 1.0, fitStartFraction: Double = 0.2,
                    unwrap: Bool = true) {
            self.species = species
            self.timestep_fs = timestep_fs
            self.frameInterval_ps = frameInterval_ps
            self.fitStartFraction = fitStartFraction
            self.unwrap = unwrap
        }
    }

    public static let defaultParameters = Parameters()

    /// One walk of the trajectory on the first call of a generation, one
    /// subtraction per atom afterwards.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 0.3 * Double(atoms) }

    // MARK: - Trajectory-level series

    /// MSD over the whole trajectory, plus the fit. Computed once per
    /// (generation, parameters) and reused by every frame.
    public struct Series: Equatable {
        public let time_ps: [Double]
        public let msd: [Double]              // Å²
        /// Cumulative displacement per atom at each frame — the per-frame field
        /// comes straight out of this, so playback costs nothing.
        public let squaredDisplacement: [[Float]]
        public let referenceIndex: Int
        public let fitFrom: Int
        public let slope: Double              // Å²/ps
        public let slopeStandardError: Double
        public let atomsCounted: Int
        public let unwrapped: Bool
        /// Largest single-frame step seen; > L/2 means unwrapping is unreliable.
        public let maxStep: Double

        public var diffusion_A2_per_ps: Double { slope / 6 }
        public var diffusionSE_A2_per_ps: Double { slopeStandardError / 6 }
        /// 1 Å²/ps = 1e-20 m² / 1e-12 s = 1e-8 m²/s = 1e-4 cm²/s.
        public static let cm2PerS_perA2PerPs = 1e-4
    }

    private struct CacheKey: Hashable {
        let generation: Int
        let reference: Int
        let species: String?
        let unwrap: Bool
        let fitStartFraction: Double
        let timestep_fs: Double
        let frameInterval_ps: Double
        let stride: Int
        let frames: Int
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: Series] = [:]

    /// Trajectory-level MSD. Frames are walked once from the reference frame;
    /// unwrapping needs consecutive frames, so this cannot be done per frame.
    public static func series(trajectory: Trajectory, referenceIndex: Int,
                              params: Parameters, stride: Int = 1,
                              isCancelled: () -> Bool = { false }) throws -> Series {
        let frames = trajectory.count
        guard frames > 0 else { throw AnalysisError.notApplicable("Empty trajectory.") }
        let ref = min(max(0, referenceIndex), frames - 1)
        let n = trajectory[ref].count
        let step = max(1, stride)

        var selected: [Int] = []
        for i in 0..<n where (params.species == nil || trajectory[ref].atoms[i].element == params.species!)
                          && i % step == 0 {
            selected.append(i)
        }
        guard !selected.isEmpty else {
            throw AnalysisError.notApplicable("No atoms match species “\(params.species ?? "any")”.")
        }

        var msd = [Double](repeating: 0, count: frames)
        var fields = [[Float]](repeating: [], count: frames)
        var time = [Double](repeating: 0, count: frames)
        var maxStep = 0.0

        // Frames before the reference are walked backwards from it, so a
        // reference in the middle of a trajectory still gives |Δr| for all.
        func walk(_ order: [Int]) throws {
            var disp = [SIMD3<Double>](repeating: .zero, count: n)
            var prev = trajectory[ref].positions
            for f in order {
                if isCancelled() { throw AnalysisError.cancelled }
                let frame = trajectory[f]
                guard frame.count == n else {
                    // Atom count changed: nothing can be matched from here on.
                    msd[f] = .nan
                    fields[f] = [Float](repeating: 0, count: frame.count)
                    time[f] = timeOf(frame, index: f, params: params)
                    continue
                }
                let pos = frame.positions
                for i in 0..<n {
                    var d = pos[i] - prev[i]
                    if params.unwrap, let box = frame.box { d = box.minimumImage(d) }
                    let m = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
                    if m > maxStep { maxStep = m }
                    disp[i] += d
                }
                prev = pos
                var sum = 0.0
                var values = [Float](repeating: 0, count: n)
                for i in selected {
                    let d = disp[i]
                    let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                    sum += d2
                    values[i] = Float(d2)
                }
                msd[f] = sum / Double(selected.count)
                fields[f] = values
                time[f] = timeOf(frame, index: f, params: params)
            }
        }

        try walk(Array((ref + 1)..<frames))
        try walk(Array((0..<ref).reversed()))
        msd[ref] = 0
        fields[ref] = [Float](repeating: 0, count: n)
        time[ref] = timeOf(trajectory[ref], index: ref, params: params)

        // Fit MSD = 6·D·t over the tail. Times are measured from the reference
        // frame so the intercept is free rather than forced through zero.
        let t0 = time[ref]
        var xs: [Double] = [], ys: [Double] = []
        let ordered = (0..<frames).filter { $0 >= ref && msd[$0].isFinite }.sorted()
        let skip = Int((Double(ordered.count) * min(max(params.fitStartFraction, 0), 0.9)).rounded(.down))
        let fitFrom = ordered.isEmpty ? ref : ordered[min(skip, ordered.count - 1)]
        for f in ordered where f >= fitFrom {
            xs.append(time[f] - t0)
            ys.append(msd[f])
        }
        let (slope, se) = leastSquaresSlope(x: xs, y: ys)

        return Series(time_ps: time, msd: msd, squaredDisplacement: fields,
                      referenceIndex: ref, fitFrom: fitFrom, slope: slope,
                      slopeStandardError: se, atomsCounted: selected.count,
                      unwrapped: params.unwrap, maxStep: maxStep)
    }

    static func timeOf(_ frame: Frame, index: Int, params: Parameters) -> Double {
        if let ts = frame.timestep { return Double(ts) * params.timestep_fs / 1000 }
        return Double(index) * params.frameInterval_ps
    }

    /// Ordinary least squares slope and its standard error. Fewer than three
    /// points, or no spread in x, gives NaN rather than a fabricated number.
    static func leastSquaresSlope(x: [Double], y: [Double]) -> (slope: Double, standardError: Double) {
        let n = Double(min(x.count, y.count))
        guard n >= 3 else { return (.nan, .nan) }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<Int(n) { sxx += (x[i] - mx) * (x[i] - mx); sxy += (x[i] - mx) * (y[i] - my) }
        guard sxx > 0 else { return (.nan, .nan) }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        var residual = 0.0
        for i in 0..<Int(n) {
            let e = y[i] - (intercept + slope * x[i])
            residual += e * e
        }
        let se = (residual / (n - 2) / sxx).squareRoot()
        return (slope, se)
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard let reference = context.referenceFrame else {
            throw AnalysisError.missingRequirement(.referenceFrame)
        }
        guard frame.count > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        guard reference.count == frame.count else {
            throw AnalysisError.notApplicable(
                "Reference frame has \(reference.count) atoms and this frame has \(frame.count) — "
                + "atoms cannot be matched.")
        }

        var notes: [String] = []
        let refIndex = context.referenceFrameIndex ?? 0
        var series: Series?
        if let trajectory = context.trajectory, trajectory.count > 1 {
            let key = CacheKey(generation: context.trajectoryGeneration, reference: refIndex,
                               species: params.species, unwrap: params.unwrap,
                               fitStartFraction: params.fitStartFraction,
                               timestep_fs: params.timestep_fs,
                               frameInterval_ps: params.frameInterval_ps,
                               stride: max(1, context.stride), frames: trajectory.count)
            cacheLock.lock()
            let hit = context.trajectoryGeneration != 0 ? cache[key] : nil
            cacheLock.unlock()
            if let hit {
                series = hit
            } else {
                let built = try self.series(trajectory: trajectory, referenceIndex: refIndex,
                                            params: params, stride: context.stride,
                                            isCancelled: context.isCancelled)
                if context.trajectoryGeneration != 0 {
                    cacheLock.lock()
                    if cache.count > 8 { cache.removeAll() }   // one open trajectory at a time
                    cache[key] = built
                    cacheLock.unlock()
                }
                series = built
            }
        }

        // Per-frame numbers: from the trajectory walk when we have it, else a
        // single reference→now difference (which cannot unwrap).
        let n = frame.count
        var values = [Float](repeating: 0, count: n)
        var msdNow = Double.nan
        var counted = 0
        if let s = series, context.frameIndex >= 0, context.frameIndex < s.msd.count,
           s.squaredDisplacement[context.frameIndex].count == n {
            values = s.squaredDisplacement[context.frameIndex]
            msdNow = s.msd[context.frameIndex]
            counted = s.atomsCounted
        } else {
            if params.unwrap {
                notes.append("No trajectory in this context: displacement is the minimum image of "
                             + "r(now) − r(reference), which under-reports once an atom has crossed "
                             + "more than half a box.")
            }
            let now = frame.positions, was = reference.positions
            let stride = max(1, context.stride)
            var sum = 0.0
            for i in 0..<n where (params.species == nil || frame.atoms[i].element == params.species!)
                              && i % stride == 0 {
                var d = now[i] - was[i]
                if params.unwrap, let box = frame.box { d = box.minimumImage(d) }
                let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                values[i] = Float(d2)
                sum += d2
                counted += 1
            }
            guard counted > 0 else {
                throw AnalysisError.notApplicable("No atoms match species “\(params.species ?? "any")”.")
            }
            msdNow = sum / Double(counted)
        }

        func fmt(_ x: Double, _ digits: Int = 4) -> String {
            x.isFinite ? String(format: "%.\(digits)g", x) : "—"
        }
        var summary: [SummaryRow] = [
            SummaryRow("Species", params.species ?? "all"),
            SummaryRow("Atoms followed", "\(counted)"),
            SummaryRow("MSD (this frame)", fmt(msdNow), unit: "Å²")
        ]
        if let s = series {
            let d = s.diffusion_A2_per_ps, se = s.diffusionSE_A2_per_ps
            summary.append(SummaryRow("Time (this frame)",
                                      fmt(s.time_ps[min(max(0, context.frameIndex), s.time_ps.count - 1)]
                                          - s.time_ps[s.referenceIndex]), unit: "ps"))
            summary.append(SummaryRow("D (Einstein, MSD = 6Dt)",
                                      "\(fmt(d)) ± \(fmt(se, 2))", unit: "Å²/ps"))
            summary.append(SummaryRow("D",
                                      "\(fmt(d * Series.cm2PerS_perA2PerPs)) ± "
                                      + "\(fmt(se * Series.cm2PerS_perA2PerPs, 2))", unit: "cm²/s"))
            summary.append(SummaryRow("Fit range",
                                      "frames \(s.fitFrom)–\(s.msd.count - 1) "
                                      + "(last \(Int((1 - min(max(params.fitStartFraction, 0), 0.9)) * 100)) %)"))
            summary.append(SummaryRow("Unwrapped", s.unwrapped ? "yes (minimum image per step)" : "no"))
            if s.unwrapped, let box = frame.box {
                let half = ([box.lengths.x, box.lengths.y, box.lengths.z].filter { $0 > 0 }.min() ?? 0) / 2
                if half > 0 && s.maxStep > half {
                    notes.append(String(format: "An atom moved %.3g Å in one frame, more than half the "
                                        + "shortest box edge (%.3g Å) — unwrapping cannot tell that step "
                                        + "from its periodic image, so D is a lower bound.", s.maxStep, half))
                }
            }
        } else {
            notes.append("Only one frame is loaded: MSD is reported, D needs a series.")
        }
        if !params.unwrap {
            notes.append("unwrap = false: in a periodic cell MSD saturates at the box size and D is wrong.")
        }
        if context.stride > 1 { notes.append("Preview: 1/\(context.stride) of atoms are followed.") }

        let hi = Float(max(msdNow.isFinite && msdNow > 0 ? msdNow * 3 : 1, 1e-6))
        let field = PerAtomField(name: "displacement²", values: values,
                                 palette: .continuous(min: 0, max: hi, colormapName: "viridis"),
                                 legendTitle: "|Δr|² (Å²)")
        return ToolResult(summary: summary, field: field, profile: nil, scalar: msdNow, notes: notes)
    }
}
