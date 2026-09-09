//
//  InteractionEnergy.swift — the energetic side files, read the way ForceCurve
//  reads force_curve.csv.
//
//  `mmgbsa.py` (delivery/module1) writes two CSVs next to the trajectory:
//
//    interaction_energy.csv   frame, resname, resid, chain, e_vdw_kJ_mol, e_elec_kJ_mol
//                             per receptor residue, ligand–residue, in vacuum
//    mmgbsa.csv               frame, dG_bind_kJ_mol, e_vdw, e_elec,
//                             g_solv_complex, g_solv_receptor, g_solv_ligand, …
//
//  Both are optional: with them the Adhesion tool can say *how strongly* a
//  residue holds the ligand, not only that it touches it. MM/GBSA with a single
//  trajectory and no entropy term is a rank-order estimate, never a binding
//  free energy, and every result that quotes it says so.
//

import Foundation

/// Per-residue ligand–residue interaction energies, by frame.
public struct InteractionEnergyTable: Equatable {

    public struct Row: Equatable {
        public let frame: Int
        public let resname: String
        public let resid: String
        public let chain: String
        public let vdw: Double
        public let elec: Double
        public var total: Double { vdw + elec }
        /// Matches the Adhesion tool's per-residue label ("ASP 3").
        public var displayKey: String {
            let base = resname.isEmpty ? resid : "\(resname) \(resid)"
            return chain.isEmpty ? base : "\(chain):\(base)"
        }
    }

    public let rows: [Row]
    public var frames: [Int] { Array(Set(rows.map(\.frame))).sorted() }
    public var isEmpty: Bool { rows.isEmpty }

    /// Rows for `frame`, or for the nearest frame present (a strided MM/GBSA
    /// run has energies every N frames; the viewer is on any frame).
    public func rows(nearestTo frame: Int) -> (frame: Int, rows: [Row])? {
        guard !rows.isEmpty else { return nil }
        let available = frames
        guard let best = available.min(by: { abs($0 - frame) < abs($1 - frame) }) else { return nil }
        return (best, rows.filter { $0.frame == best })
    }

    // MARK: Parsing

    /// Header-driven, tolerant, CRLF-safe (Python's csv writes "\r\n", which is
    /// one Swift Character — splitting on "\n" would see one giant line).
    public static func parse(_ text: String) -> InteractionEnergyTable {
        var index: [String: Int] = [:]
        var out: [Row] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if index.isEmpty {
                for (i, name) in cells.enumerated() where index[name] == nil { index[name] = i }
                if index["e_vdw_kJ_mol"] != nil || index["e_elec_kJ_mol"] != nil { continue }
                return InteractionEnergyTable(rows: [])          // headerless: not our file
            }
            func cell(_ key: String) -> String? {
                guard let i = index[key], i < cells.count else { return nil }
                return cells[i]
            }
            guard let frame = cell("frame").flatMap({ Double($0) }).map({ Int($0) }),
                  let vdw = cell("e_vdw_kJ_mol").flatMap({ Double($0) }),
                  let elec = cell("e_elec_kJ_mol").flatMap({ Double($0) }),
                  vdw.isFinite, elec.isFinite else { continue }
            out.append(Row(frame: frame, resname: cell("resname") ?? "", resid: cell("resid") ?? "",
                           chain: cell("chain") ?? "", vdw: vdw, elec: elec))
        }
        return InteractionEnergyTable(rows: out)
    }

    private static let cache = FileCache<InteractionEnergyTable>()
    public static func load(_ url: URL) throws -> InteractionEnergyTable {
        try cache.value(for: url) { parse(try String(contentsOf: $0, encoding: .utf8)) }
    }

    public static let fileName = "interaction_energy.csv"
    public static func locate(near url: URL) -> URL? { SideFile.locate(fileName, near: url) }
}

/// Whole-complex MM/GBSA, by frame.
public struct MMGBSATable: Equatable {

    public struct Row: Equatable {
        public let frame: Int
        public let dG: Double
        public let vdw: Double
        public let elec: Double
        public let solvComplex: Double
        public let solvReceptor: Double
        public let solvLigand: Double
        public var solvBind: Double { solvComplex - solvReceptor - solvLigand }
    }

    public let rows: [Row]
    public var isEmpty: Bool { rows.isEmpty }

    public func row(nearestTo frame: Int) -> Row? {
        rows.min { abs($0.frame - frame) < abs($1.frame - frame) }
    }

    /// Mean and (sample) standard deviation of ΔG_bind over the recorded frames.
    /// sd is nil with fewer than two frames — one number is not a spread.
    public var statistics: (mean: Double, sd: Double?)? {
        let v = rows.map(\.dG).filter { $0.isFinite }
        guard !v.isEmpty else { return nil }
        let mean = v.reduce(0, +) / Double(v.count)
        guard v.count > 1 else { return (mean, nil) }
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1)
        return (mean, variance.squareRoot())
    }

    public static func parse(_ text: String) -> MMGBSATable {
        var index: [String: Int] = [:]
        var out: [Row] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if index.isEmpty {
                for (i, name) in cells.enumerated() where index[name] == nil { index[name] = i }
                if index["dG_bind_kJ_mol"] != nil { continue }
                return MMGBSATable(rows: [])
            }
            func num(_ key: String) -> Double? {
                guard let i = index[key], i < cells.count else { return nil }
                return Double(cells[i])
            }
            guard let frame = num("frame").map({ Int($0) }), let dG = num("dG_bind_kJ_mol"), dG.isFinite
            else { continue }
            out.append(Row(frame: frame, dG: dG, vdw: num("e_vdw") ?? 0, elec: num("e_elec") ?? 0,
                           solvComplex: num("g_solv_complex") ?? 0,
                           solvReceptor: num("g_solv_receptor") ?? 0,
                           solvLigand: num("g_solv_ligand") ?? 0))
        }
        return MMGBSATable(rows: out)
    }

    private static let cache = FileCache<MMGBSATable>()
    public static func load(_ url: URL) throws -> MMGBSATable {
        try cache.value(for: url) { parse(try String(contentsOf: $0, encoding: .utf8)) }
    }

    public static let fileName = "mmgbsa.csv"
    public static func locate(near url: URL) -> URL? { SideFile.locate(fileName, near: url) }

    /// The caveat every quoted ΔG carries. Single-trajectory MM/GBSA with no
    /// entropy term ranks poses; it does not predict affinities.
    public static let caveat =
        "MM/GBSA (single trajectory, no entropy term) is a rank-order estimate, not a binding free energy."
}

/// Where a side file lives relative to a trajectory — the same search
/// `ForceCurve.locate` uses (beside it, in a `results*/` sibling, or in the run
/// directory above when the trajectory itself sits in `results*/`).
public enum SideFile {
    public static func locate(_ name: String, near url: URL) -> URL? {
        searchLocations(name, near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func searchLocations(_ name: String, near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        let dir = looksLikeDir ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
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
