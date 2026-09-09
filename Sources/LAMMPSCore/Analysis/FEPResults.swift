//
//  FEPResults.swift — the side file an RBFE (FEP) run leaves behind.
//
//  Schema "mdengine.fep.results/1", written by delivery/fep/rbfe_openfe.py
//  analyze. Every field past the two ligand names is optional: a network that
//  is still running, an edge whose estimate failed, a producer one version
//  ahead — all must load and render, because a half-finished network is
//  exactly when someone opens the viewer.
//

import Foundation

/// A JSON scalar, for `settings` — the producer writes strings, ints and
/// doubles in the same dictionary and the tool only ever prints them.
public enum JSONScalar: Codable, Equatable {
    case string(String), double(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public var text: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "—"
        case .double(let d): return d == d.rounded() && abs(d) < 1e9
            ? String(Int(d)) : String(format: "%g", d)
        }
    }
}

public struct FEPResults: Codable, Equatable {

    public struct Edge: Codable, Equatable {
        public let ligA: String
        public let ligB: String
        public let ddG_kcal: Double?
        public let ddG_err: Double?
        public let dG_solvent: Double?
        public let dG_complex: Double?
        public let overlap_min: Double?
        public let converged: Bool?
        public let notes: String?
        public var name: String { "\(ligA)→\(ligB)" }
    }

    public struct Ligand: Codable, Equatable {
        public let name: String
        public let dG_abs_kcal: Double?
        public let dG_abs_err: Double?
        public let rank: Int?
    }

    public struct Cycle: Codable, Equatable {
        public let ligands: [String]
        public let closure_kcal: Double?
        public let closure_err: Double?
    }

    public struct Provenance: Codable, Equatable {
        public let openfe: String?, openmm: String?, openff: String?
        public let gufe: String?, cinnabar: String?, rdkit: String?
        public let date: String?, host: String?
    }

    public let schema: String?
    public let demo: Bool?
    public let forcefield: String?
    public let settings: [String: JSONScalar]?
    public let edges: [Edge]
    public let ligands: [Ligand]
    public let cycles: [Cycle]?
    public let flags: [String]?
    public let absolute_method: String?
    public let provenance: Provenance?

    /// Missing arrays decode as empty, not as a failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo)
        forcefield = try c.decodeIfPresent(String.self, forKey: .forcefield)
        settings = try c.decodeIfPresent([String: JSONScalar].self, forKey: .settings)
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        ligands = try c.decodeIfPresent([Ligand].self, forKey: .ligands) ?? []
        cycles = try c.decodeIfPresent([Cycle].self, forKey: .cycles)
        flags = try c.decodeIfPresent([String].self, forKey: .flags)
        absolute_method = try c.decodeIfPresent(String.self, forKey: .absolute_method)
        provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance)
    }

    /// Ligands in rank order; a file with no ranks falls back to ΔG order.
    public var ranked: [Ligand] {
        ligands.sorted {
            switch ($0.rank, $1.rank) {
            case let (a?, b?): return a < b
            default: return ($0.dG_abs_kcal ?? .greatestFiniteMagnitude)
                          < ($1.dG_abs_kcal ?? .greatestFiniteMagnitude)
            }
        }
    }

    public var isDemo: Bool { demo == true }

    // MARK: - Loading (cached by path + mtime + size, like ForceCurve)

    private static let cache = FileCache<FEPResults>()

    public static func load(_ url: URL) throws -> FEPResults {
        try cache.value(for: url) {
            try JSONDecoder().decode(FEPResults.self, from: try Data(contentsOf: $0))
        }
    }

    /// `results.json` for a trajectory: beside it, in a `results*/` sibling, or
    /// — when the trajectory itself lives in `results*/` — one level up.
    public static func locate(near url: URL) -> URL? {
        searchLocations(near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func searchLocations(near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        let dir = looksLikeDir ? url.standardizedFileURL
                               : url.deletingLastPathComponent().standardizedFileURL
        var out = [dir.appendingPathComponent("results.json")]
        out += ForceCurve.resultsChildren(of: dir).map { $0.appendingPathComponent("results.json") }
        if dir.lastPathComponent.hasPrefix("results") {
            let up = dir.deletingLastPathComponent()
            out.append(up.appendingPathComponent("results.json"))
            out += ForceCurve.resultsChildren(of: up).map { $0.appendingPathComponent("results.json") }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}
