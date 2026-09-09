//
//  RAMDResults.swift — the τRAMD protocol's side files, and the kinetics on them.
//
//  `tramd.py` (delivery module 1) writes `tramd_times.csv` — one row per replica,
//  its dissociation time and whether it was censored — and `tramd_survival.csv`,
//  a per-seed survival curve. This file parses both (cached by path+mtime; the
//  tool re-reads them on every frame otherwise) and holds the pure kinetics: the
//  Kokh τ (interpolated 50 % point of the sorted replica times), the bootstrap
//  CI over replicas, the censored fraction, and the survival curve the chart
//  draws.
//
//  τRAMD gives a RELATIVE k_off. Nothing here turns it into an absolute
//  residence time, and every result carries `koffCaveat` saying so.
//

import Foundation

public struct RAMDResults: Equatable {

    /// One RAMD replica: how long it stayed on, and whether it ever left.
    public struct Replica: Equatable {
        public let seed: Int
        public let replica: Int
        /// Dissociation time, or the cap the replica ran to when `censored`.
        public let time_ps: Double
        public let censored: Bool
        public let finalDistance_nm: Double

        public init(seed: Int, replica: Int, time_ps: Double, censored: Bool, finalDistance_nm: Double = 0) {
            self.seed = seed
            self.replica = replica
            self.time_ps = time_ps
            self.censored = censored
            self.finalDistance_nm = finalDistance_nm
        }
    }

    /// The replicas of one independently equilibrated start.
    public struct SeedGroup: Equatable {
        public let seed: Int
        public let times_ps: [Double]
        public let censored: [Bool]
        public var count: Int { times_ps.count }
        public var dissociated: Int { censored.filter { !$0 }.count }
    }

    public struct SurvivalPoint: Equatable {
        public let t_ps: Double
        public let seed: Int
        public let fractionBound: Double
    }

    public let replicas: [Replica]
    public let survival: [SurvivalPoint]

    public init(replicas: [Replica], survival: [SurvivalPoint] = []) {
        self.replicas = replicas
        self.survival = survival
    }

    /// Replicas grouped by seed, in first-seen order (the CSV's order).
    public var seeds: [SeedGroup] {
        var order: [Int] = []
        var bySeed: [Int: (t: [Double], c: [Bool])] = [:]
        for r in replicas {
            if bySeed[r.seed] == nil { bySeed[r.seed] = ([], []); order.append(r.seed) }
            bySeed[r.seed]!.t.append(r.time_ps)
            bySeed[r.seed]!.c.append(r.censored)
        }
        return order.map { SeedGroup(seed: $0, times_ps: bySeed[$0]!.t, censored: bySeed[$0]!.c) }
    }

    /// The per-replica cap: censored replicas are known only to be ≥ this.
    public var maxTime_ps: Double { replicas.map { $0.time_ps }.max() ?? 0 }

    public var censoredFraction: Double {
        guard !replicas.isEmpty else { return 1 }
        return Double(replicas.filter { $0.censored }.count) / Double(replicas.count)
    }

    // MARK: - τ

    /// Kokh τ: sort the replica times (censored ones at `maxTime_ps`), then read
    /// the empirical CDF at 50 % by linear interpolation. nil when fewer than
    /// half the replicas dissociated — the median is not bracketed then, and a
    /// number there would be a guess.
    public static func tau(times: [Double], censored: [Bool], maxTime_ps: Double) -> Double? {
        let n = times.count
        guard n > 0, times.count == censored.count else { return nil }
        guard censored.filter({ !$0 }).count * 2 >= n else { return nil }
        let ts = zip(times, censored).map { $1 ? maxTime_ps : $0 }.sorted()
        var xs: [Double] = [0], ys: [Double] = [0]
        for (i, t) in ts.enumerated() {
            xs.append(t)
            ys.append(Double(i + 1) / Double(n))
        }
        for i in 1..<ys.count where ys[i] >= 0.5 {
            if ys[i] == ys[i - 1] { return xs[i] }
            let f = (0.5 - ys[i - 1]) / (ys[i] - ys[i - 1])
            return xs[i - 1] + f * (xs[i] - xs[i - 1])
        }
        return nil
    }

    public func tau(for group: SeedGroup) -> Double? {
        Self.tau(times: group.times_ps, censored: group.censored, maxTime_ps: maxTime_ps)
    }

    public var tauPerSeed: [(seed: Int, tau: Double?)] {
        seeds.map { ($0.seed, tau(for: $0)) }
    }

    /// τ = mean of the per-seed τ (Kokh); nil when no seed has one.
    public var tau: Double? {
        let ts = tauPerSeed.compactMap { $0.tau }
        return ts.isEmpty ? nil : ts.reduce(0, +) / Double(ts.count)
    }

    /// 95 % CI by resampling replicas WITHIN each seed — the replicas are the
    /// repeated draws, the seeds are the starts. Seeded, so a chart and a test
    /// see the same interval twice.
    public func bootstrapCI(samples: Int = 2000, rngSeed: UInt64 = 148,
                            percentiles: (Double, Double) = (2.5, 97.5)) -> (lo: Double, hi: Double)? {
        let groups = seeds.filter { tau(for: $0) != nil }
        guard !groups.isEmpty, samples > 0 else { return nil }
        let tMax = maxTime_ps
        var rng = SplitMix64(seed: rngSeed)
        var draws: [Double] = []
        draws.reserveCapacity(samples)
        for _ in 0..<samples {
            var taus: [Double] = []
            for g in groups {
                let k = g.count
                var t: [Double] = [], c: [Bool] = []
                t.reserveCapacity(k); c.reserveCapacity(k)
                for _ in 0..<k {
                    let i = Int(rng.next() % UInt64(k))
                    t.append(g.times_ps[i]); c.append(g.censored[i])
                }
                if let v = Self.tau(times: t, censored: c, maxTime_ps: tMax) { taus.append(v) }
            }
            if !taus.isEmpty { draws.append(taus.reduce(0, +) / Double(taus.count)) }
        }
        guard draws.count >= 10 else { return nil }
        draws.sort()
        return (percentile(draws, percentiles.0), percentile(draws, percentiles.1))
    }

    func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let pos = (p / 100) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    // MARK: - survival curve

    /// Fraction of ALL replicas still bound at `t_ps`. Censored replicas count
    /// as bound throughout — that is what censoring means.
    public func fractionBound(at t_ps: Double) -> Double {
        guard !replicas.isEmpty else { return .nan }
        let bound = replicas.filter { $0.censored || $0.time_ps > t_ps }.count
        return Double(bound) / Double(replicas.count)
    }

    /// The time axis a frame index walks when no frame interval is known: the
    /// survival file's own grid, else 0 plus the distinct replica times.
    public var timeAxis: [Double] {
        if !survival.isEmpty {
            var seen = Set<Double>()
            let grid = survival.map { $0.t_ps }.filter { seen.insert($0).inserted }.sorted()
            if grid.count > 1 { return grid }
        }
        var seen = Set<Double>([0])
        return ([0] + replicas.map { $0.time_ps }.filter { seen.insert($0).inserted }).sorted()
    }

    /// Frame index → time: `frameTime_ps` when the caller knows it, else the
    /// CSV's own axis (clamped at its end).
    public func time(forFrame index: Int, frameTime_ps: Double?) -> Double? {
        if let dt = frameTime_ps, dt > 0 { return Double(index) * dt }
        let axis = timeAxis
        guard !axis.isEmpty else { return nil }
        return axis[min(max(0, index), axis.count - 1)]
    }

    /// The one sentence that must travel with every τRAMD number.
    public static let koffCaveat =
        "τRAMD gives relative k_off — rank order within one target, calibrated per target. Not an absolute residence time."

    // MARK: - Parsing

    /// Header-driven and tolerant, like the force-curve parser: unknown columns
    /// ignored, missing ones defaulted, non-finite rows dropped.
    ///
    /// Python's csv module writes CRLF, and "\r\n" is ONE Swift Character, so a
    /// split on "\n" would see the whole file as a single line — split on any
    /// newline (the gotcha the trajectory parsers hit; CLAUDE.md).
    public static func parseTimes(_ text: String) -> [Replica] {
        var out: [Replica] = []
        var index: [String: Int] = [:]
        var nextReplica = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if index.isEmpty {
                for (i, name) in cells.enumerated() where index[name] == nil { index[name] = i }
                if index["t_diss_ps"] != nil { continue }          // that was the header
                return []                                           // headerless: not our file
            }
            func cell(_ key: String) -> String? {
                guard let i = index[key], i < cells.count, !cells[i].isEmpty else { return nil }
                return cells[i]
            }
            func num(_ key: String) -> Double? { cell(key).flatMap(Double.init) }
            guard let t = num("t_diss_ps"), t.isFinite else { continue }
            let censored: Bool = {
                guard let raw = cell("censored")?.lowercased() else { return false }
                if let d = Double(raw) { return d != 0 }
                return raw == "true" || raw == "yes"
            }()
            let dist = num("final_com_distance_nm") ?? 0
            let seed = num("seed").map { Int($0) } ?? 0
            let rep = num("replica").map { Int($0) } ?? nextReplica
            nextReplica = rep + 1
            out.append(Replica(seed: seed, replica: rep, time_ps: t, censored: censored,
                               finalDistance_nm: dist.isFinite ? dist : 0))
        }
        return out
    }

    public static func parseSurvival(_ text: String) -> [SurvivalPoint] {
        var out: [SurvivalPoint] = []
        var index: [String: Int] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if index.isEmpty {
                for (i, name) in cells.enumerated() where index[name] == nil { index[name] = i }
                if index["t_ps"] != nil { continue }
                return []
            }
            func num(_ key: String) -> Double? {
                guard let i = index[key], i < cells.count else { return nil }
                return Double(cells[i])
            }
            guard let t = num("t_ps"), let f = num("fraction_bound"), t.isFinite, f.isFinite else { continue }
            out.append(SurvivalPoint(t_ps: t, seed: num("seed").map { Int($0) } ?? 0, fractionBound: f))
        }
        return out
    }

    // MARK: - Loading (cached by path + mtime + size)

    private static let cache = FileCache<RAMDResults>()

    /// `tramd_times.csv`, plus `tramd_survival.csv` when it sits beside it.
    public static func load(_ url: URL) throws -> RAMDResults {
        try cache.value(for: url) { u in
            let replicas = parseTimes(try String(contentsOf: u, encoding: .utf8))
            let survivalURL = u.deletingLastPathComponent().appendingPathComponent("tramd_survival.csv")
            let survival = (try? String(contentsOf: survivalURL, encoding: .utf8)).map(parseSurvival) ?? []
            return RAMDResults(replicas: replicas, survival: survival)
        }
    }

    /// Same search as the force curve: beside the trajectory, in a `results*/`
    /// sibling, or — when the trajectory itself lives in `results*/` — in the
    /// run directory one level up (and its other `results*/` children).
    public static func locate(near url: URL) -> URL? {
        searchLocations(near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func searchLocations(near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        let dir = looksLikeDir ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
        let name = "tramd_times.csv"
        var out = [dir.appendingPathComponent(name)]
        out += ForceCurve.resultsChildren(of: dir).map { $0.appendingPathComponent(name) }
        if dir.lastPathComponent.hasPrefix("results") {
            let up = dir.deletingLastPathComponent()
            out.append(up.appendingPathComponent(name))
            out += ForceCurve.resultsChildren(of: up).map { $0.appendingPathComponent(name) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}

/// Deterministic RNG for the bootstrap: the CI must not move between runs, and
/// a test must be able to assert the same interval twice.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
