//
//  ConformationTool.swift — "what shape is it in, and has it changed?"
//
//  The biomolecular counterpart of the Falk–Langer strain tool: instead of a
//  local affine fit it asks global questions about a trajectory — how far this
//  frame has drifted from the reference (RMSD after optimal superposition), how
//  compact it is (radius of gyration), which atoms actually move (RMSF), what
//  the backbone hydrogen bonds say (DSSP), which conformational basins the
//  trajectory visits (clustering of frames by pairwise RMSD) and along which
//  collective coordinates it moves (PCA of the superposed coordinates).
//
//  Per-frame numbers are cheap; the trajectory-level ones are not, so they are
//  computed once per (trajectory generation × parameters) and cached — the
//  frame-by-frame scrub through a 500-frame trajectory then costs one fit.
//

import Foundation

public struct ConformationTool: AnalysisTool {
    public static let id = "conformation"
    public static let title = "Conformation (RMSD · Rg · DSSP · clusters)"
    public static let category = ToolCategory.structureOrder
    public static let functions: Set<ToolFunction> = [.perAtomField, .scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = []
    /// Superposition is a global fit — a strided subset would move the answer.
    public static let supportsStridedPreview = false

    /// Frames above this go into the distance matrix by subsampling; the rest
    /// are assigned to the nearest medoid afterwards.
    public static let clusterFrameCap = 400

    public struct Parameters: Codable, Equatable {
        /// "ca" | "backbone" | "heavy" | "all" — the atoms fitted and measured.
        public var selection: String
        /// Field shown: "rmsf" | "dssp" | "displacement".
        public var quantity: String
        /// k for k-medoids, when `clusterRMSDCutoff` is nil.
        public var clusterCount: Int
        /// Set = gromos-style cutoff clustering (Daura 1999) at this RMSD (Å).
        public var clusterRMSDCutoff: Double?
        public var pcaComponents: Int
        /// Restrict the whole study to a subset (chain A, one molecule…).
        public var group: GroupSelector?

        public init(selection: String = "ca", quantity: String = "rmsf",
                    clusterCount: Int = 4, clusterRMSDCutoff: Double? = nil,
                    pcaComponents: Int = 2, group: GroupSelector? = nil) {
            self.selection = selection
            self.quantity = quantity
            self.clusterCount = clusterCount
            self.clusterRMSDCutoff = clusterRMSDCutoff
            self.pcaComponents = pcaComponents
            self.group = group
        }
    }

    public static let defaultParameters = Parameters()

    public static func estimatedCost(atoms: Int, params: Parameters) -> Double {
        0.4 * Double(atoms)                       // one fit + one Rg pass per frame
    }

    // MARK: - Trajectory-level results (computed once, cached)

    struct TrajectoryStats {
        var frameCount = 0
        var sampledFrames: [Int] = []
        var rmsf: [Double] = []                    // per selected atom, Å
        var meanStructure: [SIMD3<Double>] = []
        var clusterOfFrame: [Int] = []             // per frame, 0-based, −1 = unknown
        var populations: [Int] = []
        var medoidFrames: [Int] = []
        var pcMean: [Double] = []                  // 3N, superposed
        var pcVectors: [[Double]] = []             // components × 3N
        var pcFraction: [Double] = []              // variance explained, 0…1
        var notes: [String] = []
    }

    /// Test hook: how many times the trajectory pass actually ran.
    static var trajectoryComputations = 0
    private static let cacheLock = NSLock()
    private static var cache: [(key: String, stats: TrajectoryStats)] = []
    private static let cacheCapacity = 3

    static func resetCache() {
        cacheLock.lock(); cache.removeAll(); trajectoryComputations = 0; cacheLock.unlock()
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard frame.count > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        var notes: [String] = []

        let groupIndices: [Int]? = params.group.map { Groups.indices($0, in: frame) }
        if let g = groupIndices, g.isEmpty {
            throw AnalysisError.notApplicable("The group “\(params.group!.describedText)” selects no atoms.")
        }
        let selection = AtomSelection.select(params.selection, in: frame, within: groupIndices)
        if let n = selection.note { notes.append(n) }
        guard !selection.indices.isEmpty else {
            throw AnalysisError.notApplicable("Selection “\(params.selection)” matched no atoms.")
        }

        let trajectory = context.trajectory ?? [frame]
        let referenceIndex = context.referenceFrameIndex ?? 0
        let reference = context.referenceFrame ?? trajectory.first ?? frame
        guard reference.count == frame.count else {
            throw AnalysisError.notApplicable(
                "The reference frame has \(reference.count) atoms and this one \(frame.count) — no atom correspondence.")
        }

        let sel = selection.indices
        let refCoords = coords(reference, sel)
        let fit = Superposition.fit(mobile: coords(frame, sel), reference: refCoords)
        guard let fit else { throw AnalysisError.notApplicable("Superposition failed (degenerate selection).") }

        // Radius of gyration over the group (mass-weighted; the mass table is
        // small, so an exotic element weighs 12 rather than vanishing).
        let rgIndices = groupIndices ?? Array(0..<frame.count)
        let rg = radiusOfGyration(frame, rgIndices)

        var summary: [SummaryRow] = [
            SummaryRow("RMSD to reference", fmt(fit.rmsd), unit: "Å"),
            SummaryRow("RMSD without fit",
                       fmt(Superposition.rmsdNoFit(coords(frame, sel), refCoords)), unit: "Å"),
            SummaryRow("Radius of gyration", fmt(rg), unit: "Å"),
            SummaryRow("Selection", "\(selection.resolved) (\(sel.count) atoms)"),
            SummaryRow("Reference frame", "\(referenceIndex)")
        ]

        // --- trajectory-level ------------------------------------------------
        var stats: TrajectoryStats? = nil
        if trajectory.count >= 2 {
            stats = trajectoryStats(trajectory: trajectory, reference: reference, selection: sel,
                                    params: params, context: context,
                                    key: cacheKey(context: context, params: params,
                                                  selection: selection, frames: trajectory.count,
                                                  referenceIndex: referenceIndex))
        } else {
            notes.append("One frame only — RMSF, clustering and PCA need a trajectory.")
        }

        if let s = stats {
            notes.append(contentsOf: s.notes)
            let meanRMSF = s.rmsf.isEmpty ? 0 : s.rmsf.reduce(0, +) / Double(s.rmsf.count)
            summary.append(SummaryRow("Mean RMSF", fmt(meanRMSF), unit: "Å"))
            if let maxRMSF = s.rmsf.max() { summary.append(SummaryRow("Max RMSF", fmt(maxRMSF), unit: "Å")) }
            let cluster = (context.frameIndex >= 0 && context.frameIndex < s.clusterOfFrame.count)
                ? s.clusterOfFrame[context.frameIndex] : -1
            summary.append(SummaryRow("Cluster of this frame",
                                      cluster >= 0 ? "\(cluster + 1) of \(s.populations.count)" : "—"))
            summary.append(SummaryRow("Cluster populations",
                                      s.populations.map(String.init).joined(separator: ", "), unit: "frames"))
            let projections = project(frame: frame, selection: sel, reference: refCoords, stats: s)
            for (k, p) in projections.enumerated() {
                summary.append(SummaryRow("PC\(k + 1) projection",
                                          "\(fmt(p)) (\(fmt(s.pcFraction[k] * 100)) % of variance)", unit: "Å"))
            }
        }

        // --- the per-atom field ------------------------------------------------
        var field: PerAtomField? = nil
        var quantity = params.quantity.trimmingCharacters(in: .whitespaces).lowercased()
        if quantity == "rmsf" && stats == nil {
            quantity = "displacement"
            notes.append("RMSF needs a trajectory — showing displacement from the reference instead.")
        }
        switch quantity {
        case "dssp":
            if let ss = DSSP.analyze(frame: frame) {
                field = PerAtomField(name: "dssp", values: ss.perAtomClass,
                                     palette: .categorical([
                                        ("coil", RGB(0.62, 0.62, 0.62)),
                                        ("helix (H/G/I)", RGB(0.85, 0.20, 0.16)),
                                        ("strand (E/B)", RGB(0.94, 0.78, 0.18)),
                                        ("turn / bend (T/S)", RGB(0.24, 0.66, 0.38))]),
                                     legendTitle: "secondary structure")
                summary.append(SummaryRow("Secondary structure",
                                          String(format: "%.0f %% helix, %.0f %% strand, %.0f %% turn",
                                                 ss.fraction(SecondaryStructure.helixLetters) * 100,
                                                 ss.fraction(SecondaryStructure.strandLetters) * 100,
                                                 ss.fraction(SecondaryStructure.turnLetters) * 100),
                                          unit: "\(ss.residueCount) residues"))
            } else {
                notes.append("DSSP needs atom names (extended XYZ name column).")
            }
        case "rmsf":
            if let s = stats, s.rmsf.count == sel.count {
                var values = [Float](repeating: 0, count: frame.count)
                for (k, i) in sel.enumerated() { values[i] = Float(s.rmsf[k]) }
                let hi = Float(max(s.rmsf.max() ?? 1, 1e-6))
                field = PerAtomField(name: "rmsf", values: values,
                                     palette: .continuous(min: 0, max: hi, colormapName: "inferno"),
                                     legendTitle: "RMSF (Å)")
            }
        default:
            var values = [Float](repeating: 0, count: frame.count)
            var hi = 0.0
            for i in 0..<frame.count {
                let p = fit.apply(SIMD3(frame.atoms[i].x, frame.atoms[i].y, frame.atoms[i].z))
                let q = SIMD3(reference.atoms[i].x, reference.atoms[i].y, reference.atoms[i].z)
                let d = ((p - q) * (p - q)).sum().squareRoot()
                values[i] = Float(d); hi = max(hi, d)
            }
            if quantity != "displacement" {
                notes.append("Unknown quantity “\(params.quantity)” — showing displacement (rmsf, dssp, displacement).")
            }
            field = PerAtomField(name: "displacement", values: values,
                                 palette: .continuous(min: 0, max: Float(max(hi, 1e-6)), colormapName: "inferno"),
                                 legendTitle: "displacement from reference (Å)")
        }

        return ToolResult(summary: summary, field: field, profile: nil, scalar: fit.rmsd, notes: notes)
    }

    // MARK: - Per-frame helpers

    static func coords(_ frame: Frame, _ indices: [Int]) -> [SIMD3<Double>] {
        indices.map { SIMD3(frame.atoms[$0].x, frame.atoms[$0].y, frame.atoms[$0].z) }
    }

    /// Mass-weighted Rg (Å) over `indices`, positions as stored.
    static func radiusOfGyration(_ frame: Frame, _ indices: [Int]) -> Double {
        var total = 0.0, com = SIMD3<Double>(repeating: 0)
        for i in indices {
            let m = Groups.mass(of: frame.atoms[i].element)
            com += SIMD3(frame.atoms[i].x, frame.atoms[i].y, frame.atoms[i].z) * m
            total += m
        }
        guard total > 0 else { return 0 }
        com /= total
        var sum = 0.0
        for i in indices {
            let m = Groups.mass(of: frame.atoms[i].element)
            let d = SIMD3(frame.atoms[i].x, frame.atoms[i].y, frame.atoms[i].z) - com
            sum += m * (d * d).sum()
        }
        return (sum / total).squareRoot()
    }

    private static func project(frame: Frame, selection: [Int], reference: [SIMD3<Double>],
                                stats: TrajectoryStats) -> [Double] {
        guard !stats.pcVectors.isEmpty,
              let fit = Superposition.fit(mobile: coords(frame, selection), reference: reference)
        else { return [] }
        var x = [Double](repeating: 0, count: selection.count * 3)
        for (k, i) in selection.enumerated() {
            let p = fit.apply(SIMD3(frame.atoms[i].x, frame.atoms[i].y, frame.atoms[i].z))
            x[3 * k] = p.x - stats.pcMean[3 * k]
            x[3 * k + 1] = p.y - stats.pcMean[3 * k + 1]
            x[3 * k + 2] = p.z - stats.pcMean[3 * k + 2]
        }
        return stats.pcVectors.map { v in zip(v, x).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    private static func fmt(_ x: Double) -> String { String(format: "%.4g", x) }

    // MARK: - Trajectory pass (cached)

    private static func cacheKey(context: AnalysisContext, params: Parameters,
                                 selection: AtomSelection.Selection, frames: Int,
                                 referenceIndex: Int) -> String? {
        guard context.trajectoryGeneration != 0 else { return nil }   // ephemeral: never cached
        let group = params.group?.describedText ?? "all"
        return "g\(context.trajectoryGeneration)|n\(frames)|ref\(referenceIndex)|\(selection.resolved)"
            + "|\(selection.indices.count)|k\(params.clusterCount)|c\(params.clusterRMSDCutoff ?? -1)"
            + "|p\(params.pcaComponents)|\(group)"
    }

    private static func trajectoryStats(trajectory: Trajectory, reference: Frame, selection: [Int],
                                        params: Parameters, context: AnalysisContext,
                                        key: String?) -> TrajectoryStats {
        if let key {
            cacheLock.lock()
            let hit = cache.first { $0.key == key }?.stats
            cacheLock.unlock()
            if let hit { return hit }
        }
        let stats = computeTrajectoryStats(trajectory: trajectory, reference: reference,
                                           selection: selection, params: params, context: context)
        if let key {
            cacheLock.lock()
            cache.removeAll { $0.key == key }
            cache.append((key, stats))
            if cache.count > cacheCapacity { cache.removeFirst(cache.count - cacheCapacity) }
            cacheLock.unlock()
        }
        return stats
    }

    private static func computeTrajectoryStats(trajectory: Trajectory, reference: Frame,
                                               selection: [Int], params: Parameters,
                                               context: AnalysisContext) -> TrajectoryStats {
        cacheLock.lock(); trajectoryComputations += 1; cacheLock.unlock()
        var stats = TrajectoryStats()
        let n = selection.count, m = trajectory.count
        stats.frameCount = m
        let refCoords = coords(reference, selection)

        let stride = m > clusterFrameCap ? (m + clusterFrameCap - 1) / clusterFrameCap : 1
        if stride > 1 {
            stats.notes.append("Clustering and PCA use every \(stride)ᵗʰ frame (\(m) frames); "
                             + "the rest are assigned to the nearest medoid.")
        }

        // One pass: superpose, accumulate RMSF, keep the sampled coordinates.
        var sum = [SIMD3<Double>](repeating: .init(repeating: 0), count: n)
        var sumSq = [Double](repeating: 0, count: n)
        var sampled: [[SIMD3<Double>]] = []
        var used = 0
        for (t, f) in trajectory.enumerated() {
            guard f.count == reference.count else { continue }
            guard let fit = Superposition.fit(mobile: coords(f, selection), reference: refCoords) else { continue }
            var fitted = [SIMD3<Double>](repeating: .init(repeating: 0), count: n)
            for (k, i) in selection.enumerated() {
                let p = fit.apply(SIMD3(f.atoms[i].x, f.atoms[i].y, f.atoms[i].z))
                fitted[k] = p
                sum[k] += p
                sumSq[k] += (p * p).sum()
            }
            used += 1
            if t % stride == 0 { sampled.append(fitted); stats.sampledFrames.append(t) }
            if context.isCancelled() { break }
        }
        guard used > 0 else { return stats }

        let inv = 1.0 / Double(used)
        stats.meanStructure = sum.map { $0 * inv }
        stats.rmsf = (0..<n).map { k in
            let mean = sum[k] * inv
            return max(0, sumSq[k] * inv - (mean * mean).sum()).squareRoot()
        }

        // --- clustering by pairwise RMSD (each pair superposed) --------------
        let s = sampled.count
        if s >= 2 {
            var d = [[Double]](repeating: [Double](repeating: 0, count: s), count: s)
            for i in 0..<s {
                for j in (i + 1)..<s {
                    let r = Superposition.rmsd(mobile: sampled[i], reference: sampled[j])
                    d[i][j] = r.isFinite ? r : 0
                    d[j][i] = d[i][j]
                }
                if context.isCancelled() { break }
            }
            let clustered: (medoids: [Int], assign: [Int])
            if let cutoff = params.clusterRMSDCutoff {
                clustered = gromos(d, cutoff: cutoff)
                stats.notes.append(String(format: "Gromos clustering, RMSD cutoff %.2f Å.", cutoff))
            } else {
                clustered = kMedoids(d, k: max(1, min(params.clusterCount, s)))
            }
            // Renumber so cluster 1 is the most populated.
            var counts = [Int](repeating: 0, count: clustered.medoids.count)
            for a in clustered.assign where a >= 0 { counts[a] += 1 }
            let order = counts.indices.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0] > counts[$1] }
            var rank = [Int](repeating: 0, count: order.count)
            for (newIndex, old) in order.enumerated() { rank[old] = newIndex }
            stats.medoidFrames = order.map { stats.sampledFrames[clustered.medoids[$0]] }
            stats.populations = order.map { counts[$0] }

            var perFrame = [Int](repeating: -1, count: m)
            for (i, t) in stats.sampledFrames.enumerated() where clustered.assign[i] >= 0 {
                perFrame[t] = rank[clustered.assign[i]]
            }
            if stride > 1 {
                let medoidCoords = order.map { sampled[clustered.medoids[$0]] }
                var populations = [Int](repeating: 0, count: medoidCoords.count)
                for (t, f) in trajectory.enumerated() {
                    guard f.count == reference.count else { continue }
                    if perFrame[t] >= 0 { populations[perFrame[t]] += 1; continue }
                    guard let fit = Superposition.fit(mobile: coords(f, selection), reference: refCoords)
                    else { continue }
                    let fitted = selection.map { fit.apply(SIMD3(f.atoms[$0].x, f.atoms[$0].y, f.atoms[$0].z)) }
                    var best = 0, bestD = Double.greatestFiniteMagnitude
                    for (c, medoid) in medoidCoords.enumerated() {
                        let r = Superposition.rmsd(mobile: fitted, reference: medoid)
                        if r.isFinite && r < bestD { bestD = r; best = c }
                    }
                    perFrame[t] = best; populations[best] += 1
                    if context.isCancelled() { break }
                }
                stats.populations = populations
            }
            stats.clusterOfFrame = perFrame
        }

        // --- PCA of the superposed coordinates --------------------------------
        if s >= 2 && params.pcaComponents > 0 {
            let d3 = n * 3
            var x = [[Double]](repeating: [Double](repeating: 0, count: d3), count: s)
            var mean = [Double](repeating: 0, count: d3)
            for (i, frameCoords) in sampled.enumerated() {
                for k in 0..<n {
                    x[i][3 * k] = frameCoords[k].x
                    x[i][3 * k + 1] = frameCoords[k].y
                    x[i][3 * k + 2] = frameCoords[k].z
                }
                for j in 0..<d3 { mean[j] += x[i][j] }
            }
            for j in 0..<d3 { mean[j] /= Double(s) }
            var total = 0.0
            for i in 0..<s { for j in 0..<d3 { x[i][j] -= mean[j]; total += x[i][j] * x[i][j] } }
            total /= Double(s)
            stats.pcMean = mean
            let (vectors, values) = principalComponents(x, count: min(params.pcaComponents, min(s - 1, d3)))
            stats.pcVectors = vectors
            stats.pcFraction = values.map { total > 0 ? $0 / total : 0 }
        }
        return stats
    }

    // MARK: - Clustering

    /// Deterministic k-medoids: farthest-point seeding, then alternate assign /
    /// re-medoid until nothing moves. No RNG — the same trajectory clusters the
    /// same way twice.
    static func kMedoids(_ d: [[Double]], k: Int) -> (medoids: [Int], assign: [Int]) {
        let n = d.count
        guard n > 0, k > 0 else { return ([], []) }
        var medoids: [Int] = [(0..<n).min { a, b in d[a].reduce(0, +) < d[b].reduce(0, +) } ?? 0]
        while medoids.count < min(k, n) {
            let next = (0..<n).filter { !medoids.contains($0) }
                .max { a, b in (medoids.map { d[a][$0] }.min() ?? 0) < (medoids.map { d[b][$0] }.min() ?? 0) }
            guard let next else { break }
            medoids.append(next)
        }
        var assign = [Int](repeating: 0, count: n)
        for _ in 0..<50 {
            for i in 0..<n {
                var best = 0, bestD = Double.greatestFiniteMagnitude
                for (c, med) in medoids.enumerated() where d[i][med] < bestD { bestD = d[i][med]; best = c }
                assign[i] = best
            }
            var moved = false
            for c in medoids.indices {
                let members = (0..<n).filter { assign[$0] == c }
                guard !members.isEmpty else { continue }
                let best = members.min { a, b in
                    members.reduce(0) { $0 + d[a][$1] } < members.reduce(0) { $0 + d[b][$1] }
                }!
                if best != medoids[c] { medoids[c] = best; moved = true }
            }
            if !moved { break }
        }
        return (medoids, assign)
    }

    /// Daura's gromos clustering: take the frame with the most neighbours
    /// within `cutoff` as a cluster centre, remove it and its neighbours,
    /// repeat. Cluster count comes out of the data.
    static func gromos(_ d: [[Double]], cutoff: Double) -> (medoids: [Int], assign: [Int]) {
        let n = d.count
        var assign = [Int](repeating: -1, count: n)
        var medoids: [Int] = []
        var remaining = Set(0..<n)
        while !remaining.isEmpty {
            var best = remaining.first!, bestCount = -1
            for i in remaining.sorted() {
                let c = remaining.filter { d[i][$0] <= cutoff }.count
                if c > bestCount { bestCount = c; best = i }
            }
            let members = remaining.filter { d[best][$0] <= cutoff }
            for i in members { assign[i] = medoids.count }
            medoids.append(best)
            remaining.subtract(members)
        }
        return (medoids, assign)
    }

    // MARK: - PCA

    /// Leading eigenvectors of the covariance of `x` (rows = frames, already
    /// centred) by power iteration with Gram–Schmidt deflation — the covariance
    /// itself (3N × 3N) is never formed.
    static func principalComponents(_ x: [[Double]], count: Int) -> (vectors: [[Double]], values: [Double]) {
        let m = x.count
        guard m > 0, count > 0 else { return ([], []) }
        let d = x[0].count
        var vectors: [[Double]] = [], values: [Double] = []
        for c in 0..<min(count, d) {
            var v = x[c % m]
            orthogonalize(&v, against: vectors)
            if !normalize(&v) {
                v = [Double](repeating: 0, count: d); v[c % d] = 1
                orthogonalize(&v, against: vectors)
                if !normalize(&v) { break }
            }
            var lambda = 0.0
            for _ in 0..<200 {
                var w = [Double](repeating: 0, count: d)
                for row in x {
                    var dot = 0.0
                    for j in 0..<d { dot += row[j] * v[j] }
                    if dot != 0 { for j in 0..<d { w[j] += dot * row[j] } }
                }
                for j in 0..<d { w[j] /= Double(m) }
                orthogonalize(&w, against: vectors)
                var next = w
                lambda = normalizeReturningNorm(&next)
                if lambda <= 0 { break }
                var delta = 0.0
                for j in 0..<d { delta += abs(next[j] - v[j]) }
                v = next
                if delta < 1e-12 { break }
            }
            guard lambda > 0 else { break }
            vectors.append(v); values.append(lambda)
        }
        return (vectors, values)
    }

    private static func orthogonalize(_ v: inout [Double], against basis: [[Double]]) {
        for b in basis {
            var dot = 0.0
            for j in v.indices { dot += v[j] * b[j] }
            for j in v.indices { v[j] -= dot * b[j] }
        }
    }

    @discardableResult
    private static func normalizeReturningNorm(_ v: inout [Double]) -> Double {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-14 else { return 0 }
        for j in v.indices { v[j] /= norm }
        return norm
    }

    private static func normalize(_ v: inout [Double]) -> Bool { normalizeReturningNorm(&v) > 0 }
}
