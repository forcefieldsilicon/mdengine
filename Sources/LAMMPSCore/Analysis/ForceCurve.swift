//
//  ForceCurve.swift — the SMD protocol's side file, and the energetics on it.
//
//  `smd_pull.py` writes `force_curve.csv` next to the trajectory (one row per
//  recorded update, same cadence as the XYZ frames) and `config.json` in the
//  run directory above it. This file parses both, caches them by path+mtime
//  (the tool re-reads them on every frame otherwise), and holds the pure
//  functions the pull-off energetics tool reports: F*, W, rupture index,
//  Bell–Evans, Jarzynski.
//

import Foundation

/// One pull (one Langevin seed) out of `force_curve.csv`.
public struct ForceCurve {

    public struct Seed: Equatable {
        public let seed: Int
        public let time_ps: [Double]
        public let refDisp: [Double]          // nm, reference (spring anchor) travel
        public let comDisp: [Double]          // nm, ligand COM displacement
        public let force_pN: [Double]         // spring force
        public let force_kJ_mol_nm: [Double]  // the same force in the CSV's native units
        public let work: [Double]             // kJ/mol, running ∫F·dx_ref from the protocol
        public let contacts: [Int]

        public var count: Int { time_ps.count }

        /// Median reporting interval, for time-based frame alignment.
        public var reportInterval_ps: Double? {
            guard time_ps.count > 1 else { return nil }
            // `(i: Int)` spelled out: left implicit, the solver weighs every integer/Double overload of the
            // subscript arithmetic and times out on Linux (GJOB-190).
            let d = (1..<time_ps.count).map { (i: Int) -> Double in time_ps[i] - time_ps[i - 1] }.filter { $0 > 0 }
            return d.isEmpty ? nil : Energetics.median(d)
        }
    }

    public let seeds: [Seed]

    public var rowCount: Int { seeds.reduce(0) { $0 + $1.count } }
    public func seed(_ id: Int) -> Seed? { seeds.first { $0.seed == id } }

    /// 1 kJ/mol/nm expressed in pN (the protocol's force unit conversion).
    public static let kJmolNmInPN = 1.66053906717

    // MARK: - Parsing

    /// Header-driven and tolerant: unknown columns are ignored, absent ones
    /// read as zero, non-finite or short rows are dropped (same policy as the
    /// trajectory parsers). Rows are grouped by `seed`, in first-seen order.
    public static func parse(_ text: String) -> ForceCurve {
        struct Builder {
            var seed: Int
            var t: [Double] = [], ref: [Double] = [], com: [Double] = []
            var fpN: [Double] = [], fkJ: [Double] = [], w: [Double] = [], c: [Int] = []
        }
        var order: [Int] = []
        var builders: [Int: Builder] = [:]
        var index: [String: Int] = [:]

        // Python's csv module writes CRLF; "\r\n" is ONE Swift Character, so a
        // split on "\n" would see the whole file as a single line (the same
        // gotcha the trajectory parsers hit — CLAUDE.md). Split on any newline.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if index.isEmpty {
                for (i, name) in cells.enumerated() where index[name] == nil { index[name] = i }
                if index["time_ps"] != nil || index["force_pN"] != nil || index["force_kJ_mol_nm"] != nil {
                    continue                                  // that was the header
                }
                index.removeAll()                             // headerless: not our file
                return ForceCurve(seeds: [])
            }
            func num(_ key: String) -> Double? {
                guard let i = index[key], i < cells.count else { return nil }
                return Double(cells[i])
            }
            guard let t = num("time_ps") else { continue }
            let fkJ = num("force_kJ_mol_nm")
            let fpN = num("force_pN") ?? fkJ.map { $0 * kJmolNmInPN }
            guard let force_pN = fpN, t.isFinite, force_pN.isFinite else { continue }
            let force_kJ = fkJ ?? force_pN / kJmolNmInPN
            let ref = num("ref_disp_nm") ?? 0, com = num("com_disp_nm") ?? 0
            let w = num("work_kJ_mol") ?? 0
            guard ref.isFinite, com.isFinite, w.isFinite, force_kJ.isFinite else { continue }
            let sid = num("seed").map { Int($0) } ?? 0

            if builders[sid] == nil { builders[sid] = Builder(seed: sid); order.append(sid) }
            builders[sid]!.t.append(t)
            builders[sid]!.ref.append(ref)
            builders[sid]!.com.append(com)
            builders[sid]!.fpN.append(force_pN)
            builders[sid]!.fkJ.append(force_kJ)
            builders[sid]!.w.append(w)
            builders[sid]!.c.append(Int(num("n_contacts_total") ?? 0))
        }
        return ForceCurve(seeds: order.compactMap { builders[$0] }.map {
            Seed(seed: $0.seed, time_ps: $0.t, refDisp: $0.ref, comDisp: $0.com,
                 force_pN: $0.fpN, force_kJ_mol_nm: $0.fkJ, work: $0.w, contacts: $0.c)
        })
    }

    // MARK: - Loading (cached by path + mtime + size)

    private static let cache = FileCache<ForceCurve>()

    public static func load(_ url: URL) throws -> ForceCurve {
        try cache.value(for: url) { parse(try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// `force_curve.csv` for a trajectory: beside it, in a `results*/` sibling,
    /// or — when the trajectory itself lives in a `results*/` directory — in
    /// the run directory one level up (and its other `results*/` children).
    public static func locate(near url: URL) -> URL? {
        searchLocations(near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every path `locate` would try, in order — the tool quotes these when the
    /// side file is missing so the user knows where to put it.
    public static func searchLocations(near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        let dir = looksLikeDir ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
        var out = [dir.appendingPathComponent("force_curve.csv")]
        out += resultsChildren(of: dir).map { $0.appendingPathComponent("force_curve.csv") }
        if dir.lastPathComponent.hasPrefix("results") {
            let up = dir.deletingLastPathComponent()
            out.append(up.appendingPathComponent("force_curve.csv"))
            out += resultsChildren(of: up).map { $0.appendingPathComponent("force_curve.csv") }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    static func resultsChildren(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return kids.filter {
            $0.lastPathComponent.hasPrefix("results")
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// The handful of `config.json` keys the energetics need.
public struct RunConfig: Equatable {
    public let pullVelocity_A_per_ns: Double?
    public let springK_kJ_mol_nm2: Double?
    public let reportInterval_ps: Double?
    public let seeds: [Int]

    /// Spring constant in pN/nm, for the Bell–Evans loading rate.
    public var springK_pN_per_nm: Double? { springK_kJ_mol_nm2.map { $0 * ForceCurve.kJmolNmInPN } }
    /// Pull velocity in nm/s (1 Å/ns = 1e8 nm/s).
    public var pullVelocity_nm_per_s: Double? { pullVelocity_A_per_ns.map { $0 * 1e8 } }
    /// Loading rate r = k·v in pN/s.
    public var loadingRate_pN_per_s: Double? {
        guard let k = springK_pN_per_nm, let v = pullVelocity_nm_per_s else { return nil }
        return k * v
    }

    private static let cache = FileCache<RunConfig>()

    public static func load(_ url: URL) throws -> RunConfig {
        try cache.value(for: url) { u in
            let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: u)) as? [String: Any] ?? [:]
            func d(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
            let seeds = (obj["seeds"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
                ?? (obj["seed"] as? NSNumber).map { [$0.intValue] } ?? []
            return RunConfig(pullVelocity_A_per_ns: d("pull_velocity_A_per_ns"),
                             springK_kJ_mol_nm2: d("spring_k_kJ_mol_nm2"),
                             reportInterval_ps: d("report_interval_ps"), seeds: seeds)
        }
    }

    /// `config.json` beside the file, or one level up when the file sits in a
    /// `results*/` directory (the protocol's own layout).
    public static func locate(near url: URL) -> URL? {
        searchLocations(near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func searchLocations(near url: URL) -> [URL] {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = (exists ? isDir.boolValue : url.hasDirectoryPath)
            ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
        var out = [dir.appendingPathComponent("config.json")]
        let up = dir.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix("results") || up.path.count > 1 {
            out.append(up.appendingPathComponent("config.json"))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}

/// Parsed-file cache keyed by path + mtime + size: `analyze` runs once per
/// frame and must not re-read the CSV each time.
final class FileCache<Value> {
    private struct Key: Hashable { let path: String; let mtime: Double; let size: Int }
    private let lock = NSLock()
    private var entries: [(key: Key, value: Value)] = []
    private let capacity = 8

    func value(for url: URL, build: (URL) throws -> Value) throws -> Value {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(path: url.standardizedFileURL.path,
                      mtime: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                      size: (attrs?[.size] as? NSNumber)?.intValue ?? -1)
        lock.lock()
        if let hit = entries.first(where: { $0.key == key })?.value { lock.unlock(); return hit }
        lock.unlock()
        let built = try build(url)
        lock.lock()
        entries.removeAll { $0.key.path == key.path }
        entries.append((key, built))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return built
    }
}

// MARK: - Energetics

/// Pure functions on a parsed pull. No file access, no state.
public enum Energetics {

    /// Boltzmann constant in the pull-off units, pN·nm/K.
    public static let kB_pN_nm_per_K = 0.01380649
    /// Gas constant in kJ/mol/K — works come out of the protocol in kJ/mol.
    public static let R_kJ_per_mol_K = 0.008314462618

    public static func kT_pN_nm(_ temperature_K: Double) -> Double { kB_pN_nm_per_K * temperature_K }
    public static func kT_kJ_per_mol(_ temperature_K: Double) -> Double { R_kJ_per_mol_K * temperature_K }

    /// Rupture force = the peak spring force of the pull, and where it happened.
    public static func ruptureForce(_ seed: ForceCurve.Seed) -> (Fstar: Double, index: Int)? {
        guard let i = seed.force_pN.indices.max(by: { seed.force_pN[$0] < seed.force_pN[$1] }) else { return nil }
        return (seed.force_pN[i], i)
    }

    /// Work of separation: the protocol's own running ∫F·dx_ref (last value),
    /// and an independent trapezoid ∫F·dx over the COM displacement as a check.
    public static func workOfSeparation(_ seed: ForceCurve.Seed) -> (csv: Double, trapezoid: Double)? {
        guard let last = seed.work.last else { return nil }
        var acc = 0.0
        for i in 1..<max(1, seed.comDisp.count) {
            acc += 0.5 * (seed.force_kJ_mol_nm[i] + seed.force_kJ_mol_nm[i - 1])
                 * (seed.comDisp[i] - seed.comDisp[i - 1])
        }
        return (last, acc)
    }

    /// First index from which the contact count is zero and stays zero.
    public static func ruptureIndex(_ seed: ForceCurve.Seed) -> Int? {
        guard let last = seed.contacts.last, last == 0 else { return nil }
        var idx = seed.contacts.count - 1
        while idx > 0 && seed.contacts[idx - 1] == 0 { idx -= 1 }
        return idx
    }

    /// Bell–Evans: F* = (kT/x_β)·ln(r·x_β / (k_off⁰·kT)) fitted over ln(loading
    /// rate). Needs ≥ 3 distinct rates; nil otherwise (never fit two points).
    /// `loadingRate` in pN/s, `Fstar` in pN → x_β in nm, k_off⁰ in s⁻¹.
    public static func bellEvans(points: [(loadingRate: Double, Fstar: Double)],
                                 temperature_K: Double = 300)
        -> (koff0: Double, xBeta_nm: Double, slope: Double, intercept: Double)? {
        let usable = points.filter { $0.loadingRate > 0 && $0.Fstar.isFinite }
        let rates = Set(usable.map { $0.loadingRate })
        guard usable.count >= 3, rates.count >= 3 else { return nil }
        let x = usable.map { log($0.loadingRate) }, y = usable.map { $0.Fstar }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in x.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx, intercept = my - slope * mx
        guard slope.isFinite, intercept.isFinite, slope != 0 else { return nil }
        let kT = kT_pN_nm(temperature_K)
        let xBeta = kT / slope                       // slope = kT/x_β
        let koff0 = xBeta / (kT * exp(intercept / slope))
        guard xBeta.isFinite, koff0.isFinite else { return nil }
        return (koff0, xBeta, slope, intercept)
    }

    /// Jarzynski (1997) exponential average and the Park & Schulten (2004)
    /// second-order cumulant. Needs ≥ 10 pulls; below that a work is a work.
    /// `works` and `kT` in the same units (kJ/mol here).
    public static func jarzynski(works: [Double], kT: Double)
        -> (deltaF: Double, secondOrderCumulant: Double)? {
        let w = works.filter { $0.isFinite }
        guard w.count >= 10, kT > 0 else { return nil }
        let n = Double(w.count)
        let wMin = w.min()!                                   // shift for numerical stability
        let mean = w.reduce(0, +) / n
        let expAvg = w.reduce(0.0) { $0 + exp(-($1 - wMin) / kT) } / n
        guard expAvg > 0 else { return nil }
        let deltaF = wMin - kT * log(expAvg)
        let variance = w.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (deltaF, mean - variance / (2 * kT))
    }

    // MARK: distribution helpers (the protocol's rule: distributions, not means)

    public static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Tukey quartiles (median of each half, excluding the middle element).
    public static func iqr(_ xs: [Double]) -> (q1: Double, q3: Double) {
        guard xs.count > 1 else { return (median(xs), median(xs)) }
        let s = xs.sorted(), h = s.count / 2
        return (median(Array(s[0..<h])), median(Array(s[(s.count - h)...])))
    }
}
